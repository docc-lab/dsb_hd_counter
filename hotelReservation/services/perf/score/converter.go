package score

import (
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/proto"
)

// scoreEventToProto converts the in-binary ScoreEvent (with time.Time)
// into the wire-format pb.ScoreEvent for gRPC transmission. Paid only
// on the gRPC path (per active subscriber, per window). In-binary
// LogSink consumers see the native Go struct directly.
func scoreEventToProto(ev ScoreEvent) *pb.ScoreEvent {
	return &pb.ScoreEvent{
		SampleId:       ev.SampleID,
		TimestampNs:    ev.Timestamp.UnixNano(),
		Service:        ev.Service,
		P50TrendPred:   ev.P50TrendPred,
		TailTrendLabel: ev.TailTrendLabel,
		ModelVersion:   ev.ModelVersion,
		SourceKind:     ev.SourceKind,
		Y50Current:     ev.Y50Current,
		ExtPct_50:      ev.ExtPct50,
		ExtPct_90:      ev.ExtPct90,
		PredictionOn:   ev.PredictionOn,
	}
}

// passesFilter applies the client-supplied SubscribeReq filters to one
// ScoreEvent and returns true if the event should be sent to that
// subscriber. Empty filters (zero-valued req fields) pass everything.
//
// Note: only_methods is currently a no-op because ScoreEvent doesn't
// carry method identity; this would need a Sample.method field added
// to the upstream pipeline if per-method filtering becomes necessary.
func passesFilter(ev ScoreEvent, req *pb.ScoreSubscribeReq) bool {
	if req == nil {
		return true
	}
	if req.MinP50Trend > 0 && ev.P50TrendPred < req.MinP50Trend {
		return false
	}
	if req.MinTailTrend > 0 && ev.TailTrendLabel < req.MinTailTrend {
		return false
	}
	return true
}
