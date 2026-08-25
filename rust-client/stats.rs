// SPDX-FileCopyrightText: 2026 amurcanov
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use crate::events::{Events, PathHealthEvent};
use std::sync::{
    Arc,
    atomic::{AtomicI32, AtomicI64, AtomicU64, Ordering},
};
use tokio_util::sync::CancellationToken;

pub const MAX_WORKERS: usize = 162;

#[derive(Default)]
pub struct WorkerTraffic {
    pub tx_packets: AtomicU64,
    pub tx_bytes: AtomicU64,
    pub rx_packets: AtomicU64,
    pub rx_bytes: AtomicU64,
}

impl WorkerTraffic {
    pub const fn new() -> Self {
        Self {
            tx_packets: AtomicU64::new(0),
            tx_bytes: AtomicU64::new(0),
            rx_packets: AtomicU64::new(0),
            rx_bytes: AtomicU64::new(0),
        }
    }

    pub fn add_tx(&self, bytes: usize) {
        self.tx_packets.fetch_add(1, Ordering::Relaxed);
        self.tx_bytes.fetch_add(bytes as u64, Ordering::Relaxed);
    }

    pub fn add_rx(&self, bytes: usize) {
        self.rx_packets.fetch_add(1, Ordering::Relaxed);
        self.rx_bytes.fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

pub struct Stats {
    pub total_bytes_up: AtomicI64,
    pub total_bytes_down: AtomicI64,
    pub active_connections: AtomicI32,
    pub path_probes_sent: AtomicU64,
    pub path_probe_acks: AtomicU64,
    pub path_probe_misses: AtomicU64,
    pub path_probe_send_errors: AtomicU64,
    pub path_unresponsive: AtomicU64,
    pub path_scheduler_resets: AtomicU64,
    pub workers: [WorkerTraffic; MAX_WORKERS],
}

impl Default for Stats {
    fn default() -> Self {
        Self {
            total_bytes_up: AtomicI64::new(0),
            total_bytes_down: AtomicI64::new(0),
            active_connections: AtomicI32::new(0),
            path_probes_sent: AtomicU64::new(0),
            path_probe_acks: AtomicU64::new(0),
            path_probe_misses: AtomicU64::new(0),
            path_probe_send_errors: AtomicU64::new(0),
            path_unresponsive: AtomicU64::new(0),
            path_scheduler_resets: AtomicU64::new(0),
            workers: std::array::from_fn(|_| WorkerTraffic::new()),
        }
    }
}

impl Stats {
    #[inline]
    pub fn worker(&self, worker_id: usize) -> Option<&WorkerTraffic> {
        self.workers.get(worker_id.checked_sub(1)?)
    }

    pub async fn run(self: Arc<Self>, events: Events, cancel: CancellationToken) {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
        let mut path_interval = tokio::time::interval(std::time::Duration::from_secs(15));
        interval.tick().await;
        path_interval.tick().await;
        loop {
            tokio::select! {
                _ = cancel.cancelled() => return,
                _ = interval.tick() => {
                    let active = self.active_connections.load(Ordering::Relaxed);
                    let up = self.total_bytes_up.load(Ordering::Relaxed);
                    let down = self.total_bytes_down.load(Ordering::Relaxed);
                    let total_mb = (up + down) as f64 / (1024.0 * 1024.0);
                    let mut busy_workers = 0usize;
                    let mut idle_workers = 0usize;
                    let mut interval_tx_packets = 0u64;
                    let mut interval_rx_packets = 0u64;
                    let mut interval_tx_bytes = 0u64;
                    let mut interval_rx_bytes = 0u64;
                    let mut worker_lines = Vec::new();

                    // MAX_WORKERS is only the hard upper bound.  It must not be
                    // treated as the number of currently active workers.
                    //
                    // active_connections is the number of workers/sessions that
                    // are currently READY.  Only those workers participate in
                    // working/idle statistics.
                    let active_workers = (active.max(0) as usize).min(MAX_WORKERS);

                    for (index, worker) in self.workers.iter().take(active_workers).enumerate() {
                        let txp = worker.tx_packets.swap(0, Ordering::AcqRel);
                        let rxp = worker.rx_packets.swap(0, Ordering::AcqRel);
                        let txb = worker.tx_bytes.swap(0, Ordering::AcqRel);
                        let rxb = worker.rx_bytes.swap(0, Ordering::AcqRel);
                        interval_tx_packets += txp;
                        interval_rx_packets += rxp;
                        interval_tx_bytes += txb;
                        interval_rx_bytes += rxb;

                        if txp == 0 && rxp == 0 {
                            idle_workers += 1;
                        } else {
                            busy_workers += 1;
                            worker_lines.push(format!(
                                "#{:03} TX:{}/{}B RX:{}/{}B",
                                index + 1, txp, txb, rxp, rxb
                            ));
                        }
                    }
                    crate::log_error!(
                        "[СТАТИСТИКА] Активных: {active_workers} | Рабочих за 3с: {busy_workers} | В простое за 3с: {idle_workers} | Трафик: {total_mb:.2} МБ | TX:{interval_tx_packets}p/{interval_tx_bytes}B RX:{interval_rx_packets}p/{interval_rx_bytes}B"
                    );
                    if !worker_lines.is_empty() {
                        crate::log_error!("[WORKERS за 3с] {}", worker_lines.join(" | "));
                    }
                    events.stats(active, up, down);
                }
                _ = path_interval.tick() => {
                    events.path_health(PathHealthEvent {
                        active: self.active_connections.load(Ordering::Relaxed),
                        sent: self.path_probes_sent.swap(0, Ordering::AcqRel),
                        acked: self.path_probe_acks.swap(0, Ordering::AcqRel),
                        missed: self.path_probe_misses.swap(0, Ordering::AcqRel),
                        send_errors: self.path_probe_send_errors.swap(0, Ordering::AcqRel),
                        unresponsive: self.path_unresponsive.swap(0, Ordering::AcqRel),
                        scheduler_resets: self.path_scheduler_resets.swap(0, Ordering::AcqRel),
                    });
                }
            }
        }
    }
}
