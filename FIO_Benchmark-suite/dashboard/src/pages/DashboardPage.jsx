import React, { useState } from 'react';
import DiskSelector from '../components/DiskSelector';
import BenchmarkCharts from '../components/BenchmarkCharts';
import LatencyChart from '../components/LatencyChart';
import LiveTelemetry from '../components/LiveTelemetry';
import { useBenchmarkResults, useResultData } from '../hooks/useBenchmarks';

export default function DashboardPage() {
    const { resultSets, loading: loadingSets } = useBenchmarkResults();
    const [selectedSet, setSelectedSet] = useState('');
    const { data, loading: loadingData } = useResultData(selectedSet);

    return (
        <>
            {/* Page Title */}
            <div className="section" style={{ marginTop: 'var(--space-lg)' }}>
                <h1 className="section-title">⚡ Performance Dashboard</h1>
            </div>

            {/* Result Set Selector */}
            <DiskSelector
                disks={resultSets}
                selected={selectedSet}
                onChange={setSelectedSet}
                loading={loadingSets}
            />

            {/* Loading state */}
            {loadingData && <div className="loading-spinner" />}

            {/* Summary Stats */}
            {data && data.length > 0 && (
                <div className="section">
                    <div className="grid-4">
                        <div className="stat-card blue">
                            <div className="stat-label">Total Records</div>
                            <div className="stat-value">{data.length}</div>
                        </div>
                        <div className="stat-card green">
                            <div className="stat-label">Avg IOPS</div>
                            <div className="stat-value">
                                {Math.round(data.reduce((s, r) => s + (r.iops || 0), 0) / data.length).toLocaleString()}
                            </div>
                        </div>
                        <div className="stat-card purple">
                            <div className="stat-label">Avg Throughput</div>
                            <div className="stat-value">
                                {Math.round(data.reduce((s, r) => s + (r.bw_kbs || 0) / 1024, 0) / data.length).toLocaleString()}
                                <span className="stat-unit">MB/s</span>
                            </div>
                        </div>
                        <div className="stat-card amber">
                            <div className="stat-label">Avg Latency</div>
                            <div className="stat-value">
                                {Math.round(data.reduce((s, r) => s + (r.lat_mean_us || 0), 0) / data.length).toLocaleString()}
                                <span className="stat-unit">µs</span>
                            </div>
                        </div>
                    </div>
                </div>
            )}

            {/* Charts */}
            <div className="section">
                <BenchmarkCharts data={data} />
            </div>

            <div className="section">
                <LatencyChart data={data} />
            </div>

            {/* Live Telemetry */}
            <div className="section">
                <h2 className="section-title">🖥 Live Monitoring</h2>
                <LiveTelemetry />
            </div>
        </>
    );
}
