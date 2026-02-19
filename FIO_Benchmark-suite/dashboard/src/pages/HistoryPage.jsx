import React, { useState, useMemo } from 'react';
import HistoryTable from '../components/HistoryTable';
import BenchmarkCharts from '../components/BenchmarkCharts';
import LatencyChart from '../components/LatencyChart';
import ComparisonCharts from '../components/ComparisonCharts';
import { useBenchmarkResults, useResultData } from '../hooks/useBenchmarks';

const TEST_TYPE_ORDER = ['seqread', 'seqwrite', 'randread', 'randwrite', 'randrw'];

const TEST_TYPE_LABELS = {
    seqread: 'Sequential Read',
    seqwrite: 'Sequential Write',
    randread: 'Random Read',
    randwrite: 'Random Write',
    randrw: 'Random Read/Write',
};

export default function HistoryPage() {
    const { resultSets, loading, refresh } = useBenchmarkResults();
    const [selectedSet, setSelectedSet] = useState('');
    const { data, loading: loadingData } = useResultData(selectedSet);
    const [selectedTestType, setSelectedTestType] = useState('');

    // Derive available test types
    const testTypes = useMemo(() => {
        if (!data || data.length === 0) return [];
        const types = [...new Set(data.map(r => r.test_type))];
        types.sort((a, b) => {
            const ia = TEST_TYPE_ORDER.indexOf(a);
            const ib = TEST_TYPE_ORDER.indexOf(b);
            return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
        });
        return types;
    }, [data]);

    const activeTestType = useMemo(() => {
        if (selectedTestType && (testTypes.includes(selectedTestType) || selectedTestType === '__compare__')) {
            return selectedTestType;
        }
        return testTypes[0] || '';
    }, [selectedTestType, testTypes]);

    const filteredData = useMemo(() => {
        if (!data || data.length === 0) return [];
        if (activeTestType === '__compare__') return data;
        return data.filter(r => r.test_type === activeTestType);
    }, [data, activeTestType]);

    const isCompareMode = activeTestType === '__compare__';

    const handleSelect = (name) => {
        setSelectedSet(name);
        setSelectedTestType('');
    };

    return (
        <>
            <div className="section" style={{ marginTop: 'var(--space-lg)' }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                    <h1 className="section-title">📊 Historical Results</h1>
                    <button className="btn btn-secondary" onClick={refresh}>
                        🔄 Refresh
                    </button>
                </div>
            </div>

            {loading ? (
                <div className="loading-spinner" />
            ) : (
                <div className="section">
                    <HistoryTable
                        results={resultSets}
                        onSelect={handleSelect}
                        selectedName={selectedSet}
                    />
                </div>
            )}

            {loadingData && <div className="loading-spinner" />}

            {data && data.length > 0 && (
                <>
                    {/* Test Type Filter */}
                    {testTypes.length > 0 && (
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

                    {/* Data Table — filtered */}
                    <div className="section">
                        <div className="card">
                            <div className="card-header">
                                <div className="card-title">
                                    📋 Raw Data — {selectedSet}
                                    {!isCompareMode && ` — ${TEST_TYPE_LABELS[activeTestType] || activeTestType}`}
                                </div>
                                <div className="card-subtitle">{filteredData.length} records</div>
                            </div>
                            <div style={{ overflowX: 'auto' }}>
                                <table className="data-table">
                                    <thead>
                                        <tr>
                                            <th>Disk</th>
                                            <th>Test</th>
                                            <th>BS</th>
                                            <th>NJ</th>
                                            <th>IO</th>
                                            <th>Dir</th>
                                            <th>IOPS</th>
                                            <th>BW (MB/s)</th>
                                            <th>Lat Mean</th>
                                            <th>p50</th>
                                            <th>p95</th>
                                            <th>p99</th>
                                            <th>p99.9</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {filteredData.map((row, i) => (
                                            <tr key={i}>
                                                <td style={{ color: 'var(--text-primary)' }}>{row.disk}</td>
                                                <td>
                                                    <span className={`badge ${row.direction || 'read'}`}>
                                                        {row.test_type}
                                                    </span>
                                                </td>
                                                <td>{row.block_size}</td>
                                                <td>{row.numjobs}</td>
                                                <td>{row.iodepth}</td>
                                                <td>
                                                    <span className={`badge ${(row.direction || 'read').toLowerCase()}`}>
                                                        {row.direction || '—'}
                                                    </span>
                                                </td>
                                                <td>{Number(row.iops || 0).toLocaleString()}</td>
                                                <td>{Math.round((row.bw_kbs || 0) / 1024).toLocaleString()}</td>
                                                <td>{Number(row.lat_mean_us || 0).toLocaleString()} µs</td>
                                                <td>{Number(row.lat_p50_us || 0).toLocaleString()}</td>
                                                <td>{Number(row.lat_p95_us || 0).toLocaleString()}</td>
                                                <td>{Number(row.lat_p99_us || 0).toLocaleString()}</td>
                                                <td>{Number(row.lat_p999_us || 0).toLocaleString()}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>

                    {/* Charts */}
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
        </>
    );
}
