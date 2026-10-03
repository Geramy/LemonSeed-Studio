/* fw_service_test.c - mac_linuxgpu's firmware servicer against the app's
 * firmware root.
 *
 *   fw_service_test <firmware root> <firmware.lock>
 *
 * Plays the dext's side of the mailbox protocol (linuxu/headers/rt/
 * fw_mailbox.h) over an anonymous mapping that stands in for the mapped
 * MLG_FW_MAILBOX_MEMORY_TYPE region, with a data window smaller than the
 * images so every fetch is chunked. Every file the lock names is fetched by
 * its request name and checked against the lock's SHA-256 and size; then a
 * missing file, rejected names, an out-of-range offset, the counters and
 * detach. Runs on macOS; the servicer source is the same one the iPad app
 * compiles.
 */
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "fw_mailbox_service.h"
#include <rt/fw_mailbox.h>

#define WINDOW (64u * 1024u)

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; \
	fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
	fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static struct mlg_fw_mailbox *box;
static uint8_t *window;
static uint32_t seq;

static uint64_t now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
}

/* One dext round trip; returns the response status or 1 on timeout. */
static int round_trip(const char *name, uint64_t offset)
{
	uint64_t start = now_ms();

	if (++seq == 0)
		seq = 1;
	memset(box->request_name, 0, sizeof(box->request_name));
	strncpy(box->request_name, name, sizeof(box->request_name) - 1);
	box->request_offset = offset;
	__atomic_store_n(&box->request_seq, seq, __ATOMIC_RELEASE);
	while (__atomic_load_n(&box->response_seq, __ATOMIC_ACQUIRE) != seq) {
		if (now_ms() - start > 5000)
			return 1;
		usleep(200);
	}
	return box->response_status;
}

/* Fetch a whole file the way linuxu/src/fw/fw_mailbox.c does. */
static int fetch(const char *name, uint8_t **out, uint64_t *size, unsigned *chunks)
{
	uint8_t *buffer = NULL;
	uint64_t total = 0, offset = 0;

	*chunks = 0;
	do {
		int status = round_trip(name, offset);
		if (status) {
			free(buffer);
			return status;
		}
		if (!buffer) {
			total = box->response_total_size;
			buffer = malloc(total);
			if (!buffer)
				return -ENOMEM;
		}
		if (box->response_total_size != total || box->response_offset != offset ||
		    !box->response_length || box->response_length > WINDOW ||
		    box->response_length > total - offset) {
			free(buffer);
			return -EIO;
		}
		memcpy(buffer + offset, window, box->response_length);
		offset += box->response_length;
		(*chunks)++;
	} while (offset < total);
	*out = buffer;
	*size = total;
	return 0;
}

static void hex(const uint8_t *digest, char *text)
{
	for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
		sprintf(text + 2 * i, "%02x", digest[i]);
}

int main(int argc, char **argv)
{
	struct mlg_fw_service *service = NULL;
	size_t region = MLG_FW_MAILBOX_HEADER_SIZE + WINDOW;
	unsigned files = 0, chunks_total = 0;
	uint64_t bytes = 0;
	char line[1024];
	FILE *lock;
	void *memory;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <firmware root> <firmware.lock>\n", argv[0]);
		return 2;
	}
	memory = mmap(NULL, region, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
	if (memory == MAP_FAILED)
		return 2;
	box = memory;
	window = (uint8_t *)memory + MLG_FW_MAILBOX_HEADER_SIZE;

	/* A region the dext has not initialized is not a mailbox. */
	CHECK(mlg_fw_service_start(memory, region, argv[1], &service) == -EINVAL && !service,
	      "attach to an uninitialized region");

	/* The dext's fw_mailbox_attach(). */
	box->version = MLG_FW_MAILBOX_VERSION;
	box->header_size = MLG_FW_MAILBOX_HEADER_SIZE;
	box->data_capacity = WINDOW;
	__atomic_store_n(&box->magic, MLG_FW_MAILBOX_MAGIC, __ATOMIC_RELEASE);

	CHECK(mlg_fw_service_start(memory, region, argv[1], &service) == 0 && service,
	      "start the servicer");
	if (!service)
		return 1;
	CHECK(box->servicer_pid == (uint32_t)getpid(), "servicer_pid is %u", box->servicer_pid);
	CHECK(box->servicer_generation == 1, "generation %u", box->servicer_generation);
	{
		uint64_t beat = __atomic_load_n(&box->servicer_heartbeat, __ATOMIC_ACQUIRE);
		usleep(20000);
		CHECK(__atomic_load_n(&box->servicer_heartbeat, __ATOMIC_ACQUIRE) != beat,
		      "heartbeat does not advance");
	}

	lock = fopen(argv[2], "r");
	CHECK(lock != NULL, "open %s", argv[2]);
	while (lock && fgets(line, sizeof(line), lock)) {
		char path[512], want[65], got[65];
		unsigned long long size_want;
		uint8_t digest[CC_SHA256_DIGEST_LENGTH];
		uint8_t *data = NULL;
		uint64_t size = 0;
		unsigned chunks = 0;
		int status;

		if (sscanf(line, "file %511s %64s %llu", path, want, &size_want) != 3)
			continue;
		status = fetch(path, &data, &size, &chunks);
		CHECK(status == 0, "%s: status %d", path, status);
		if (status)
			continue;
		CC_SHA256(data, (CC_LONG)size, digest);
		hex(digest, got);
		CHECK(size == size_want && strcmp(got, want) == 0,
		      "%s: %llu bytes sha256 %s, lock says %llu %s", path,
		      (unsigned long long)size, got, size_want, want);
		free(data);
		files++;
		bytes += size;
		chunks_total += chunks;
	}
	if (lock)
		fclose(lock);
	CHECK(files > 0, "the lock lists no files");
	CHECK(mlg_fw_service_served(service) == files, "served %llu of %u",
	      (unsigned long long)mlg_fw_service_served(service), files);
	CHECK(mlg_fw_service_missing(service) == 0, "missing before the miss test");

	/* A file upstream asks for that is not bundled. */
	CHECK(round_trip("amdgpu/not_a_bundled_image.bin", 0) == MLG_FW_STATUS_NOENT,
	      "missing file is not NOENT");
	CHECK(mlg_fw_service_missing(service) == 1, "missing counter");

	/* Names that would leave the firmware root. */
	const char *bad[] = { "../firmware.lock", "/etc/hosts", "amdgpu/../firmware.lock",
			      "amdgpu//x.bin", "amdgpu/", "./amdgpu/x.bin", "a\\b" };
	for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
		CHECK(round_trip(bad[i], 0) == MLG_FW_STATUS_INVAL, "%s accepted", bad[i]);
	CHECK(mlg_fw_service_missing(service) == 1, "rejected names counted as missing");

	/* An offset past the end of a present file. */
	CHECK(round_trip("firmware.lock", 1ull << 40) == MLG_FW_STATUS_INVAL,
	      "offset past the end");

	mlg_fw_service_stop(service);
	CHECK(box->servicer_pid == 0, "servicer_pid after stop: %u", box->servicer_pid);

	printf("fw_service_test: %u files, %llu bytes in %u chunks of <= %u bytes; %s\n",
	       files, (unsigned long long)bytes, chunks_total, WINDOW,
	       failures ? "FAILED" : "all checks passed");
	munmap(memory, region);
	return failures ? 1 : 0;
}
