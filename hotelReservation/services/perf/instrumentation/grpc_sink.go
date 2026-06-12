package instrumentation

import (
	"net"
	"sync"
	"sync/atomic"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

// GRPCSink exposes the InstrumentationStream gRPC service. It implements
// instrumentation.Sink so it can register with a Publisher; per-window
// Emit calls fan out to every currently-connected subscriber's bounded
// channel (per-subscriber drop-on-overflow). A separate goroutine per
// subscriber serializes perf.Sample to pb.Sample and calls stream.Send.
//
// Lifecycle:
//
//	sink := NewGRPCSink(":7901", "search", logger, 64)
//	publisher.Register(sink)
//	go sink.Serve()      // blocks; run in its own goroutine
//	defer sink.Close()   // GracefulStop, then drain
//
// The proto serialization cost is paid only when a subscriber is actually
// connected; an idle sink (no subscribers) consumes ~0 CPU on the Publish
// hot path because the per-subscriber loop iterates an empty slice.
//
// Per-subscriber buffer depth: configurable via GORDION_SUBSCRIBER_BUFFER
// (default 64). Subscribers that fall behind by more than the buffer
// depth lose events; their dropped count is exposed via the dropped
// atomic and (eventually) a Prometheus metric.
type GRPCSink struct {
	addr        string
	serviceName string
	logger      zerolog.Logger
	subBufSize  int

	server   *grpc.Server
	listener net.Listener

	subsMu  sync.RWMutex
	subs    map[uint64]*subscriber
	nextSub uint64

	closed atomic.Bool
}

// subscriber is one connected gRPC client. It holds a bounded channel
// the Publisher writes into and a "done" channel that signals the
// per-stream goroutine to exit (used during graceful shutdown).
type subscriber struct {
	id      uint64
	ch      chan perf.Sample
	dropped uint64 // atomic
	done    chan struct{}
}

// NewGRPCSink constructs a GRPCSink that will listen on addr (e.g.
// ":7901") when Serve is called. serviceName is stamped into every
// emitted pb.Sample; subBufSize is the per-subscriber bounded channel
// depth (drop-on-overflow when a slow subscriber falls behind).
//
// Listening doesn't actually start until Serve() is called; this lets
// callers register the sink with a Publisher first and then start the
// listener.
func NewGRPCSink(addr, serviceName string, logger zerolog.Logger, subBufSize int) *GRPCSink {
	if subBufSize <= 0 {
		subBufSize = 64
	}
	return &GRPCSink{
		addr:        addr,
		serviceName: serviceName,
		logger:      logger,
		subBufSize:  subBufSize,
		subs:        make(map[uint64]*subscriber),
	}
}

// Serve binds the TCP listener, registers the InstrumentationStream
// service, and runs grpc.Server.Serve. Blocks until Close is called or
// the listener fails. Run in a dedicated goroutine.
func (g *GRPCSink) Serve() error {
	lis, err := net.Listen("tcp", g.addr)
	if err != nil {
		return err
	}
	g.listener = lis

	srv := grpc.NewServer()
	pb.RegisterInstrumentationStreamServer(srv, &grpcServer{sink: g})
	// Register the gRPC reflection service so tools like grpcurl can list
	// methods and decode messages without an out-of-band .proto file.
	// Cheap to expose; the schema is also publicly checked-in proto.
	reflection.Register(srv)
	g.server = srv

	g.logger.Info().
		Str("event", "instrumentation_grpc_serve").
		Str("addr", g.addr).
		Str("service", g.serviceName).
		Int("subscriber_buffer", g.subBufSize).
		Msg("InstrumentationStream gRPC server listening")

	return srv.Serve(lis)
}

// Emit is the Sink contract. Fans the Sample to all currently-connected
// subscribers via non-blocking sends; slow subscribers see their dropped
// counter incremented but never block the Publisher. A slow research
// notebook never affects a fast mitigation controller.
func (g *GRPCSink) Emit(s perf.Sample) {
	if g.closed.Load() {
		return
	}
	g.subsMu.RLock()
	defer g.subsMu.RUnlock()
	for _, sub := range g.subs {
		select {
		case sub.ch <- s:
		default:
			atomic.AddUint64(&sub.dropped, 1)
		}
	}
}

// Close gracefully stops the gRPC server (waits for in-flight streams to
// finish), then signals every active subscriber goroutine to exit. Safe
// to call once; second calls are no-ops.
func (g *GRPCSink) Close() error {
	if !g.closed.CompareAndSwap(false, true) {
		return nil
	}
	if g.server != nil {
		// GracefulStop blocks until every active Subscribe RPC returns.
		// The per-stream goroutines watch stream.Context().Done() which
		// gRPC cancels as part of GracefulStop.
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

// registerSubscriber allocates a new subscriber slot and returns it.
// Called from the gRPC Subscribe handler when a client connects.
func (g *GRPCSink) registerSubscriber() *subscriber {
	g.subsMu.Lock()
	defer g.subsMu.Unlock()
	id := atomic.AddUint64(&g.nextSub, 1)
	sub := &subscriber{
		id:   id,
		ch:   make(chan perf.Sample, g.subBufSize),
		done: make(chan struct{}),
	}
	g.subs[id] = sub
	g.logger.Info().
		Str("event", "instrumentation_subscribe").
		Uint64("sub_id", id).
		Int("active_subscribers", len(g.subs)).
		Msg("InstrumentationStream subscriber connected")
	return sub
}

// unregisterSubscriber removes a subscriber slot and logs its dropped
// count. Called from the gRPC Subscribe handler on disconnect.
func (g *GRPCSink) unregisterSubscriber(sub *subscriber) {
	g.subsMu.Lock()
	delete(g.subs, sub.id)
	remaining := len(g.subs)
	g.subsMu.Unlock()
	dropped := atomic.LoadUint64(&sub.dropped)
	g.logger.Info().
		Str("event", "instrumentation_unsubscribe").
		Uint64("sub_id", sub.id).
		Uint64("dropped", dropped).
		Int("active_subscribers", remaining).
		Msg("InstrumentationStream subscriber disconnected")
}

// grpcServer implements pb.InstrumentationStreamServer. It's a thin
// adapter that bridges the gRPC server-streaming RPC to the GRPCSink's
// subscriber registry + per-subscriber channel pattern.
type grpcServer struct {
	pb.UnimplementedInstrumentationStreamServer
	sink *GRPCSink
}

// Subscribe is the server-streaming handler. One goroutine per active
// client. It registers a subscriber slot, then loops:
//   - Read one perf.Sample from the subscriber's channel.
//   - Convert to pb.Sample.
//   - stream.Send.
//
// Returns when the client disconnects, the server stops, or stream.Send
// fails. Per-subscriber drop-on-overflow is enforced inside Emit, not
// here; this loop assumes the channel is well-formed.
func (s *grpcServer) Subscribe(req *pb.SampleSubscribeReq, stream pb.InstrumentationStream_SubscribeServer) error {
	sub := s.sink.registerSubscriber()
	defer s.sink.unregisterSubscriber(sub)

	ctx := stream.Context()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-sub.done:
			return nil
		case sample, ok := <-sub.ch:
			if !ok {
				return nil
			}
			pbSample := sampleToProto(sample, s.sink.serviceName, 0)
			if err := stream.Send(pbSample); err != nil {
				return err
			}
		}
	}
}
