package score

import (
	"net"
	"sync"
	"sync/atomic"

	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
)

// GRPCSink exposes the ContentionStream gRPC service. Symmetric to
// instrumentation.GRPCSink: implements score.Sink, fans each ScoreEvent
// to every connected subscriber's bounded channel (per-subscriber
// drop-on-overflow), per-subscriber stream.Send goroutine.
//
// Lifecycle:
//
//	sink := NewGRPCSink(":7900", logger, 64)
//	publisher.Register(sink)
//	go sink.Serve()      // blocks; run in its own goroutine
//	defer sink.Close()
//
// Per-subscriber filters (min_p50_trend, min_tail_trend) are applied in
// the per-stream goroutine before stream.Send so each subscriber only
// sees events above its own thresholds. This keeps wire bytes down for
// mitigation systems that only care about contention onset.
type GRPCSink struct {
	addr       string
	logger     zerolog.Logger
	subBufSize int

	server   *grpc.Server
	listener net.Listener

	subsMu  sync.RWMutex
	subs    map[uint64]*subscriber
	nextSub uint64

	closed atomic.Bool
}

// subscriber is one connected ContentionStream client.
type subscriber struct {
	id      uint64
	ch      chan ScoreEvent
	filters *pb.ScoreSubscribeReq
	dropped uint64 // atomic
	done    chan struct{}
}

// NewGRPCSink constructs a GRPCSink that will listen on addr (e.g.
// ":7900") when Serve is called. subBufSize is the per-subscriber
// bounded channel depth.
func NewGRPCSink(addr string, logger zerolog.Logger, subBufSize int) *GRPCSink {
	if subBufSize <= 0 {
		subBufSize = 64
	}
	return &GRPCSink{
		addr:       addr,
		logger:     logger,
		subBufSize: subBufSize,
		subs:       make(map[uint64]*subscriber),
	}
}

// Serve binds the TCP listener, registers the ContentionStream service,
// and runs grpc.Server.Serve. Blocks until Close is called or the
// listener fails. Run in a dedicated goroutine.
func (g *GRPCSink) Serve() error {
	lis, err := net.Listen("tcp", g.addr)
	if err != nil {
		return err
	}
	g.listener = lis

	srv := grpc.NewServer()
	pb.RegisterContentionStreamServer(srv, &grpcServer{sink: g})
	g.server = srv

	g.logger.Info().
		Str("event", "score_grpc_serve").
		Str("addr", g.addr).
		Int("subscriber_buffer", g.subBufSize).
		Msg("ContentionStream gRPC server listening")

	return srv.Serve(lis)
}

// Emit is the score.Sink contract. Fans ScoreEvent to all currently-
// connected subscribers via non-blocking sends; slow subscribers see
// their dropped counter incremented but never block the Publisher.
//
// Per-subscriber filters are applied here (cheap) so a subscriber that
// asked for min_tail_trend=0.5 doesn't even consume its buffer slot for
// events below the threshold.
func (g *GRPCSink) Emit(ev ScoreEvent) {
	if g.closed.Load() {
		return
	}
	g.subsMu.RLock()
	defer g.subsMu.RUnlock()
	for _, sub := range g.subs {
		if !passesFilter(ev, sub.filters) {
			continue
		}
		select {
		case sub.ch <- ev:
		default:
			atomic.AddUint64(&sub.dropped, 1)
		}
	}
}

// Close gracefully stops the gRPC server. Safe to call once.
func (g *GRPCSink) Close() error {
	if !g.closed.CompareAndSwap(false, true) {
		return nil
	}
	if g.server != nil {
		g.server.GracefulStop()
	}
	g.subsMu.Lock()
	for _, sub := range g.subs {
		close(sub.done)
	}
	g.subs = nil
	g.subsMu.Unlock()
	return nil
}

// registerSubscriber allocates a new subscriber slot.
func (g *GRPCSink) registerSubscriber(filters *pb.ScoreSubscribeReq) *subscriber {
	g.subsMu.Lock()
	defer g.subsMu.Unlock()
	id := atomic.AddUint64(&g.nextSub, 1)
	sub := &subscriber{
		id:      id,
		ch:      make(chan ScoreEvent, g.subBufSize),
		filters: filters,
		done:    make(chan struct{}),
	}
	g.subs[id] = sub
	g.logger.Info().
		Str("event", "score_subscribe").
		Uint64("sub_id", id).
		Float32("min_p50_trend", filterMinP50(filters)).
		Float32("min_tail_trend", filterMinTail(filters)).
		Int("active_subscribers", len(g.subs)).
		Msg("ContentionStream subscriber connected")
	return sub
}

func (g *GRPCSink) unregisterSubscriber(sub *subscriber) {
	g.subsMu.Lock()
	delete(g.subs, sub.id)
	remaining := len(g.subs)
	g.subsMu.Unlock()
	dropped := atomic.LoadUint64(&sub.dropped)
	g.logger.Info().
		Str("event", "score_unsubscribe").
		Uint64("sub_id", sub.id).
		Uint64("dropped", dropped).
		Int("active_subscribers", remaining).
		Msg("ContentionStream subscriber disconnected")
}

// filterMinP50 / filterMinTail are tiny helpers so the log line above
// doesn't crash on a nil request (which an over-zealous client might
// send). The standard generated *pb.ScoreSubscribeReq is nil-safe via
// protobuf's GetXxx accessors, but we also handle nil explicitly.
func filterMinP50(req *pb.ScoreSubscribeReq) float32 {
	if req == nil {
		return 0
	}
	return req.MinP50Trend
}
func filterMinTail(req *pb.ScoreSubscribeReq) float32 {
	if req == nil {
		return 0
	}
	return req.MinTailTrend
}

// grpcServer implements pb.ContentionStreamServer.
type grpcServer struct {
	pb.UnimplementedContentionStreamServer
	sink *GRPCSink
}

// Subscribe is the server-streaming handler. Mirrors the
// instrumentation side: register a subscriber, loop pulling ScoreEvents
// from its channel, convert to proto, stream.Send.
func (s *grpcServer) Subscribe(req *pb.ScoreSubscribeReq, stream pb.ContentionStream_SubscribeServer) error {
	sub := s.sink.registerSubscriber(req)
	defer s.sink.unregisterSubscriber(sub)

	ctx := stream.Context()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-sub.done:
			return nil
		case ev, ok := <-sub.ch:
			if !ok {
				return nil
			}
			if err := stream.Send(scoreEventToProto(ev)); err != nil {
				return err
			}
		}
	}
}
