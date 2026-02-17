import React, { useState } from 'react';
import HistoryTable from '../components/HistoryTable';
import BenchmarkCharts from '../components/BenchmarkCharts';
import LatencyChart from '../components/LatencyChart';
import { useBenchmarkResults, useResultData } from '../hooks/useBenchmarks';

export default function HistoryPage() {
    const { resultSets, loading, refresh } = useBenchmarkResults();
    const [selectedSet, setSelectedSet] = useState('');
    const { data, loading: loadingData } = useResultData(selectedSet);

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
                        onSelect={setSelectedSet}
                        selectedName={selectedSet}
                    />
                </div>
            )}

            {loadingData && <div className="loading-spinner" />}

            {data && data.length > 0 && (
                <>
                    {/* Data Table */}
                    <div className="section">
                        <div className="card">
                            <div className="card-header">
                                <div className="card-title">📋 Raw Data — {selectedSet}</div>
                                <div className="card-subtitle">{data.length} records</div>
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
                                        {data.map((row, i) => (
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

                    {/* Charts for selected set */}
                    <div className="section">
                        <BenchmarkCharts data={data} />
                    </div>
                    <div className="section">
                        <LatencyChart data={data} />
                    </div>
                </>
            )}
        </>
    );
}
