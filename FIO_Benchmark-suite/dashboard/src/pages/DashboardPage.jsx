import React, { useState, useMemo } from 'react';
import DiskSelector from '../components/DiskSelector';
import BenchmarkCharts from '../components/BenchmarkCharts';
import LatencyChart from '../components/LatencyChart';
import ComparisonCharts from '../components/ComparisonCharts';
import LiveTelemetry from '../components/LiveTelemetry';
import { useBenchmarkResults, useResultData } from '../hooks/useBenchmarks';

const TEST_TYPE_ORDER = ['seqread', 'seqwrite', 'randread', 'randwrite', 'randrw'];

const TEST_TYPE_LABELS = {
    seqread: 'Sequential Read',
    seqwrite: 'Sequential Write',
    randread: 'Random Read',
    randwrite: 'Random Write',
    randrw: 'Random Read/Write',
};

export default function DashboardPage() {
    const { resultSets, loading: loadingSets } = useBenchmarkResults();
    const [selectedSet, setSelectedSet] = useState('');
    const { data, loading: loadingData } = useResultData(selectedSet);
    const [selectedTestType, setSelectedTestType] = useState('');

    // Derive available test types from data
    const testTypes = useMemo(() => {
        if (!data || data.length === 0) return [];
        const types = [...new Set(data.map(r => r.test_type))];
        // Sort by predefined order
        types.sort((a, b) => {
            const ia = TEST_TYPE_ORDER.indexOf(a);
            const ib = TEST_TYPE_ORDER.indexOf(b);
            return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
        });
        return types;
    }, [data]);

    // Auto-select first test type when data changes
    const activeTestType = useMemo(() => {
        if (selectedTestType && (testTypes.includes(selectedTestType) || selectedTestType === '__compare__')) {
            return selectedTestType;
        }
        return testTypes[0] || '';
    }, [selectedTestType, testTypes]);

    // Filter data by selected test type
    const filteredData = useMemo(() => {
        if (!data || data.length === 0) return [];
        if (activeTestType === '__compare__') return data;
        return data.filter(r => r.test_type === activeTestType);
    }, [data, activeTestType]);

    // Summary stats for filtered data
    const stats = useMemo(() => {
        if (!filteredData || filteredData.length === 0) return null;
        const d = activeTestType === '__compare__' ? data : filteredData;
        const count = d.length;
        const avgIops = Math.round(d.reduce((s, r) => s + (r.iops || 0), 0) / count);
        const avgBw = Math.round(d.reduce((s, r) => s + (r.bw_kbs || 0) / 1024, 0) / count);
        const avgLat = Math.round(d.reduce((s, r) => s + (r.lat_mean_us || 0), 0) / count);
        return { count, avgIops, avgBw, avgLat };
    }, [data, filteredData, activeTestType]);

    const handleTestTypeChange = (e) => {
        setSelectedTestType(e.target.value);
    };

    const isCompareMode = activeTestType === '__compare__';

    return (
        <>
            {/* Page Title */}
            <div className="section" style={{ marginTop: 'var(--space-lg)' }}>
                <h1 className="section-title">⚡ Performance Dashboard</h1>
            </div>

            {/* Workload Selector */}
            <DiskSelector
                disks={resultSets}
                selected={selectedSet}
                onChange={(val) => { setSelectedSet(val); setSelectedTestType(''); }}
                loading={loadingSets}
            />

            {/* Loading state */}
            {loadingData && <div className="loading-spinner" />}

            {/* Test Type Filter */}
            {data && data.length > 0 && testTypes.length > 0 && (
                <div className="card filter-bar">
                    <div className="filter-bar-inner">
                        <div className="filter-label">🔬 Test Type</div>
                        <div className="filter-pills">
                            {testTypes.map(tt => (
                                <button
                                    key={tt}
                                    className={`filter-pill${activeTestType === tt ? ' active' : ''}`}
                                    onClick={() => setSelectedTestType(tt)}
                                >
                                    {TEST_TYPE_LABELS[tt] || tt}
                                </button>
                            ))}
                            <button
                                className={`filter-pill compare${isCompareMode ? ' active' : ''}`}
                                onClick={() => setSelectedTestType('__compare__')}
                            >
                                📊 Compare All
                            </button>
                        </div>
                    </div>
                </div>
            )}

            {/* Summary Stats */}
            {stats && (
                <div className="section">
                    <div className="grid-4">
                        <div className="stat-card blue">
                            <div className="stat-label">Records</div>
                            <div className="stat-value">{stats.count}</div>
                        </div>
                        <div className="stat-card green">
                            <div className="stat-label">Avg IOPS</div>
                            <div className="stat-value">{stats.avgIops.toLocaleString()}</div>
                        </div>
                        <div className="stat-card purple">
                            <div className="stat-label">Avg Throughput</div>
                            <div className="stat-value">
                                {stats.avgBw.toLocaleString()}
                                <span className="stat-unit">MB/s</span>
                            </div>
                        </div>
                        <div className="stat-card amber">
                            <div className="stat-label">Avg Latency</div>
                            <div className="stat-value">
                                {stats.avgLat.toLocaleString()}
                                <span className="stat-unit">µs</span>
                            </div>
                        </div>
                    </div>
                </div>
            )}

            {/* Charts */}
            {filteredData.length > 0 && (
                <>
                    {isCompareMode ? (
                        <div className="section">
                            <ComparisonCharts data={data} />
                        </div>
                    ) : (
                        <>
                            <div className="section">
                                <BenchmarkCharts data={filteredData} />
                            </div>
                            <div className="section">
                                <LatencyChart data={filteredData} />
                            </div>
                        </>
                    )}
                </>
            )}

            {/* Live Telemetry */}
            <div className="section">
                <h2 className="section-title">🖥 Live Monitoring</h2>
                <LiveTelemetry />
            </div>
        </>
    );
}
