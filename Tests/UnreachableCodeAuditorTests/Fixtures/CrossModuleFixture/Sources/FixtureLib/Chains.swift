// Dead chain: none of A, B, C is reachable from any entry point. The v3.1
// conservative filter only flags the head (`deadChainA`) — B and C have
// refs from A, so the per-symbol "zero incoming refs" guard keeps them
// from being flagged. Once the call-graph edges are reliable enough, the
// filter can be relaxed and the suite can assert all three.
func deadChainA() { deadChainB() }
func deadChainB() { deadChainC() }
func deadChainC() {}

// Live chain: `liveChainX` is public in a library product (= root).
// `liveChainY` and `liveChainZ` are reachable through the call graph
// and must NOT be flagged even though they are internal.
public func liveChainX() { liveChainY() }
func liveChainY() { liveChainZ() }
func liveChainZ() {}
