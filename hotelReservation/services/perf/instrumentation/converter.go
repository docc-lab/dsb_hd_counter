package instrumentation

import (
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/proto"
)

// sampleToProto converts the in-binary perf.Sample (with time.Time and
// pointer fields) into the wire-format pb.Sample for gRPC transmission.
//
// This is paid only on the gRPC path (per active subscriber, per window).
// In-binary subscribers like a score.Source consume perf.Sample directly
// and never trigger this conversion.
//
// serviceName is threaded in by the GRPCSink because perf.Sample itself
// doesn't carry the service identity (the sampler owns it via RunConfig).
//
// offsetFromWorkloadMs is a value the caller provides if they're driving
// a workload-aware harness; pass 0 if not applicable. The proto carries
// it for downstream eval that wants to align Sample timelines against a
// loadgen start.
func sampleToProto(s perf.Sample, serviceName string, offsetFromWorkloadMs int64) *pb.Sample {
	out := &pb.Sample{
		SampleId:              int32(s.SampleID),
		TimestampNs:           s.Timestamp.UnixNano(),
		OffsetMs:              s.OffsetMs,
		OffsetFromWorkloadMs:  offsetFromWorkloadMs,
		Service:               serviceName,
		PerfCounters:          s.PerfCounters,
		PerfDeltas:            s.PerfDeltas,
		TimingWindow:          timingStatsToProto(s.TimingWindow),
		Freq:                  freqToProto(s.Freq),
	}
	return out
}

func timingStatsToProto(t *interceptor.WindowTimingStats) *pb.WindowTimingStats {
	if t == nil {
		return nil
	}
	return &pb.WindowTimingStats{
		ArrivalCount:   int32(t.ArrivalCount),
		RequestCount:   int32(t.RequestCount),
		ArrivalRps_1S:  t.ArrivalRps1s,
		ArrivalRps_3S:  t.ArrivalRps3s,
		ProcessingTime: durationStatsToProto(t.ProcessingTime),
		TotalTime:      durationStatsToProto(t.TotalTime),
		BlockingTime:   durationStatsToProto(t.BlockingTime),
	}
}

func durationStatsToProto(d interceptor.WindowDurationStats) *pb.DurationStats {
	return &pb.DurationStats{
		MinNs:  d.MinNs,
		MaxNs:  d.MaxNs,
		MeanNs: d.MeanNs,
		P50Ns:  d.P50Ns,
		P60Ns:  d.P60Ns,
		P70Ns:  d.P70Ns,
		P75Ns:  d.P75Ns,
		P80Ns:  d.P80Ns,
		P90Ns:  d.P90Ns,
		P99Ns:  d.P99Ns,
		Count:  int32(d.Count),
	}
}

func freqToProto(f perf.FreqSample) *pb.FreqSample {
	return &pb.FreqSample{
		Ok:             f.OK,
		ActualFreqMhz:  f.ActualFreqMHz,
		CurrentMaxMhz:  f.CurrentMaxMHz,
		ActiveN:        int32(f.ActiveN),
		FreqUtilPct:    f.FreqUtilPct,
		TurboOn:        f.TurboOn,
		TscFreqMhz:     f.TscFreqMHz,
	}
}
