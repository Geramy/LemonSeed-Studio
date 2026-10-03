/*
 * ring_buffer.c — a lock-free single-producer, single-consumer ring buffer.
 *
 * The capacity is a power of two so wrapping is a mask, not a division.
 */
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define RING_CAPACITY 4096u
#define RING_MASK (RING_CAPACITY - 1u)

typedef struct {
    _Alignas(64) atomic_size_t head;   /* written by the producer */
    _Alignas(64) atomic_size_t tail;   /* written by the consumer */
    uint8_t data[RING_CAPACITY];
} ring_buffer;

static inline size_t ring_used(const ring_buffer *ring) {
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail;
}

bool ring_push(ring_buffer *ring, const void *bytes, size_t length) {
    if (length > RING_CAPACITY - ring_used(ring)) {
        return false;  // not enough room; the caller retries later
    }
    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    for (size_t i = 0; i < length; i++) {
        ring->data[(head + i) & RING_MASK] = ((const uint8_t *)bytes)[i];
    }
    atomic_store_explicit(&ring->head, head + length, memory_order_release);
    return true;
}

size_t ring_pop(ring_buffer *ring, void *out, size_t capacity) {
    size_t available = ring_used(ring);
    size_t count = available < capacity ? available : capacity;
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    for (size_t i = 0; i < count; i++) {
        ((uint8_t *)out)[i] = ring->data[(tail + i) & RING_MASK];
    }
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}
