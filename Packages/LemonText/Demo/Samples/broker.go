// Package broker schedules generation requests by priority over a single engine.
package broker

import (
	"container/heap"
	"context"
	"errors"
	"sync"
	"time"
)

type Priority int

const (
	Interactive Priority = iota
	Agent
	Background
)

type Request struct {
	ID        string
	Priority  Priority
	Prompt    string
	Submitted time.Time
	index     int
}

type queue []*Request

func (q queue) Len() int { return len(q) }
func (q queue) Less(i, j int) bool {
	if q[i].Priority != q[j].Priority {
		return q[i].Priority < q[j].Priority
	}
	return q[i].Submitted.Before(q[j].Submitted)
}
func (q queue) Swap(i, j int)  { q[i], q[j] = q[j], q[i]; q[i].index = i; q[j].index = j }
func (q *queue) Push(x any)    { r := x.(*Request); r.index = len(*q); *q = append(*q, r) }
func (q *queue) Pop() any {
	old := *q
	r := old[len(old)-1]
	*q = old[:len(old)-1]
	return r
}

var ErrClosed = errors.New("broker: closed")

type Broker struct {
	mu      sync.Mutex
	pending queue
	wake    chan struct{}
	closed  bool
}

func New() *Broker { return &Broker{wake: make(chan struct{}, 1)} }

func (b *Broker) Submit(r *Request) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return ErrClosed
	}
	r.Submitted = time.Now()
	heap.Push(&b.pending, r)
	select {
	case b.wake <- struct{}{}:
	default:
	}
	return nil
}

func (b *Broker) Next(ctx context.Context) (*Request, error) {
	for {
		b.mu.Lock()
		if len(b.pending) > 0 {
			r := heap.Pop(&b.pending).(*Request)
			b.mu.Unlock()
			return r, nil
		}
		b.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-b.wake:
		}
	}
}
