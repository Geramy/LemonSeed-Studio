#include "CGitShim.h"
#include <git2.h>
#include <git2/sys/filter.h>
#include <stdlib.h>
#include <string.h>

static lsg_lfs_transform_fn lfs_transform;

typedef struct {
	git_writestream parent;
	git_writestream *next;
	int to_odb;
	char *git_dir;
	char *path;
	char *data;
	size_t len, cap;
} lfs_stream;

static int lfs_stream_write(git_writestream *s, const char *buffer, size_t len)
{
	lfs_stream *st = (lfs_stream *)s;
	if (st->len + len > st->cap) {
		size_t cap = st->cap ? st->cap : 8192;
		while (cap < st->len + len)
			cap *= 2;
		char *grown = realloc(st->data, cap);
		if (!grown)
			return -1;
		st->data = grown;
		st->cap = cap;
	}
	memcpy(st->data + st->len, buffer, len);
	st->len += len;
	return 0;
}

static int lfs_stream_close(git_writestream *s)
{
	lfs_stream *st = (lfs_stream *)s;
	char *out = NULL;
	size_t out_len = 0;
	int error = 0;

	if (lfs_transform)
		error = lfs_transform(st->to_odb, st->git_dir, st->path,
		                      st->data ? st->data : "", st->len, &out, &out_len);
	if (error < 0) {
		free(out);
		return error;
	}
	if (out) {
		error = st->next->write(st->next, out, out_len);
		free(out);
	} else if (st->len) {
		error = st->next->write(st->next, st->data, st->len);
	}
	if (error < 0)
		return error;
	return st->next->close(st->next);
}

static void lfs_stream_free(git_writestream *s)
{
	lfs_stream *st = (lfs_stream *)s;
	free(st->data);
	free(st->git_dir);
	free(st->path);
	free(st);
}

static int lfs_filter_stream(git_writestream **out, git_filter *self, void **payload,
                             const git_filter_source *src, git_writestream *next)
{
	(void)self;
	(void)payload;
	lfs_stream *st = calloc(1, sizeof(*st));
	if (!st)
		return -1;
	st->parent.write = lfs_stream_write;
	st->parent.close = lfs_stream_close;
	st->parent.free = lfs_stream_free;
	st->next = next;
	st->to_odb = git_filter_source_mode(src) == GIT_FILTER_TO_ODB;
	st->git_dir = strdup(git_repository_path(git_filter_source_repo(src)));
	st->path = strdup(git_filter_source_path(src) ? git_filter_source_path(src) : "");
	*out = &st->parent;
	return 0;
}

static git_filter lfs_filter;
static int lfs_registered;

int lsg_lfs_filter_register(lsg_lfs_transform_fn transform)
{
	lfs_transform = transform;
	if (lfs_registered)
		return 0;
	git_filter_init(&lfs_filter, GIT_FILTER_VERSION);
	lfs_filter.attributes = "filter=lfs";
	lfs_filter.stream = lfs_filter_stream;
	int error = git_filter_register("lfs", &lfs_filter, GIT_FILTER_DRIVER_PRIORITY);
	if (error == 0 || error == GIT_EEXISTS)
		lfs_registered = 1;
	return error == GIT_EEXISTS ? 0 : error;
}
