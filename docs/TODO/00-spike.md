# Spike: Clustered RDMA for Supercomputing

Think about a clustered RDMA (Remote Direct Memory Access) setup for supercomputing workloads.

## Areas to Explore

- RDMA transport layer (iWARP, RoCE, InfiniBand verbs)
- Zero-copy message passing between nodes
- Integration with Fornax IPC model (Plan 9 style file interface for RDMA queues)
- Memory registration and pinning for DMA
- Scalability considerations for multi-node clusters
