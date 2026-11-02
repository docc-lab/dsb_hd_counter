package gordion

// gRPC wiring for plain (non-Blueprint) services.
//
//	opts = append(opts, gordion.ServerOptions("Reservation", []string{"MakeReservation", "CheckAvailability"})...)
//	srv := grpc.NewServer(opts...)
//
// adds the transport tap (arrival stamp before the handler goroutine exists)
// and a unary interceptor that records every completion of the listed
// methods. dialer.Dial adds ClientInterceptor to every outgoing connection:
// it stamps the request with the caller's send time (gordion-sent metadata),
// accounts the time blocked on the call to the enclosing server request
// (PauseBegin/PauseEnd), and, when GORDION_CLIENT_OUT is set, records the
// caller-observed RTT per callee endpoint.
//
// Everything is a pass-through when GORDION_OUT is unset or GORDION_DISABLE=1.

import (
	"context"
	"os"
	"strings"

	"google.golang.org/grpc"
)

// Enabled reports whether recording is configured for this process.
func Enabled() bool {
	return os.Getenv("GORDION_OUT") != "" && os.Getenv("GORDION_DISABLE") != "1"
}

// calleeMethods lists the endpoints of every HotelReservation gRPC service, by
// proto service base name, for the client-side recorders.
var calleeMethods = map[string][]string{
	"Geo":            {"Nearby"},
	"Profile":        {"GetProfiles"},
	"Rate":           {"GetRates"},
	"Recommendation": {"GetRecommendations"},
	"Reservation":    {"MakeReservation", "CheckAvailability"},
	"Search":         {"Nearby"},
	"User":           {"CheckUser"},
	"Review":         {"GetReviews"},
	"Attractions":    {"NearbyRest", "NearbyMus", "NearbyCinema"},
}

// splitMethod turns "/reservation.Reservation/MakeReservation" into
// ("Reservation", "MakeReservation").
func splitMethod(full string) (string, string) {
	key := tapKeyOf(full) // "/Reservation/MakeReservation"
	i := strings.LastIndexByte(key, '/')
	if i <= 0 {
		return "", key
	}
	return strings.TrimPrefix(key[:i], "/"), key[i+1:]
}

// ServerOptions returns the server options that record every call of the
// given methods of protoService (its base name, e.g. "Reservation"); nil when
// recording is disabled.
func ServerOptions(protoService string, methods []string) []grpc.ServerOption {
	if !Enabled() {
		return nil
	}
	rec, err := GetRecorder(strings.ToLower(protoService), protoService, methods)
	if err != nil {
		os.Stderr.WriteString("gordion: " + err.Error() + "\n")
		return nil
	}
	idx := map[string]int32{}
	for i, m := range methods {
		idx["/"+protoService+"/"+m] = int32(i)
	}
	si := func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		m, ok := idx[tapKeyOf(info.FullMethod)]
		if !ok {
			return handler(ctx, req)
		}
		ctx, tok := rec.Begin(ctx, int(m))
		resp, err := handler(ctx, req)
		rec.End(tok, err != nil)
		return resp, err
	}
	return []grpc.ServerOption{TapOption(), grpc.ChainUnaryInterceptor(si)}
}

// ClientInterceptor stamps outgoing calls, accounts blocked time to the
// enclosing request and (with GORDION_CLIENT_OUT) records the caller's view.
func ClientInterceptor() grpc.UnaryClientInterceptor {
	if os.Getenv("GORDION_DISABLE") == "1" || (os.Getenv("GORDION_OUT") == "" && os.Getenv("GORDION_CLIENT_OUT") == "") {
		return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
			return invoker(ctx, method, req, reply, cc, opts...)
		}
	}
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		ctx = Stamp(ctx)
		paused := PauseBegin(ctx)
		var crec *Recorder
		mi := -1
		if svc, m := splitMethod(method); svc != "" {
			if ms, ok := calleeMethods[svc]; ok {
				if r, err := GetClientRecorder(strings.ToLower(svc), ms); err == nil && !r.disabled {
					for i, x := range ms {
						if x == m {
							crec, mi = r, i
						}
					}
				}
			}
		}
		var tok Token
		if crec != nil {
			tok = crec.BeginCall(mi)
		}
		err := invoker(ctx, method, req, reply, cc, opts...)
		if crec != nil {
			crec.EndCall(tok, err != nil)
		}
		if paused {
			PauseEnd(ctx)
		}
		return err
	}
}
