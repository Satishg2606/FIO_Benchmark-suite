import React, { useMemo, useState, useEffect } from 'react';
import {
    LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
    ResponsiveContainer
} from 'recharts';

// Distinct colors for each iodepth line
const IO_COLORS = [
    '#10b981', // emerald
    '#3b82f6', // blue
    '#f59e0b', // amber
    '#f43f5e', // rose
    '#8b5cf6', // purple
    '#06b6d4', // cyan
    '#ec4899', // pink
    '#84cc16', // lime
];

const CustomTooltip = ({ active, payload, label }) => {
    if (!active || !payload) return null;
    return (
        <div style={{
            background: 'rgba(17, 24, 39, 0.95)',
            border: '1px solid rgba(255,255,255,0.1)',
            borderRadius: '8px',
            padding: '10px 14px',
            fontSize: '0.82rem',
            fontFamily: 'var(--font-mono)',
        }}>
            <div style={{ color: 'var(--text-muted)', marginBottom: 4 }}>numjobs={label}</div>
            {payload.map((entry, i) => (
                <div key={i} style={{ color: entry.color, marginTop: 2 }}>
                    {entry.name}: <strong>{Number(entry.value).toLocaleString()}</strong>
                </div>
            ))}
        </div>
    );
};

export default function BenchmarkCharts({ data }) {
    const [selectedIoDepths, setSelectedIoDepths] = useState(new Set());

    const { chartData, ioDepths, direction } = useMemo(() => {
        if (!data || data.length === 0) return { chartData: [], ioDepths: [], direction: 'read' };

        const dirs = [...new Set(data.map(r => (r.direction || 'read').toLowerCase()))];
        const primaryDir = dirs.includes('read') ? 'read' : dirs[0] || 'read';

        const ioSet = [...new Set(data.map(r => Number(r.iodepth) || 0))].sort((a, b) => a - b);
        const njSet = [...new Set(data.map(r => Number(r.numjobs) || 0))].sort((a, b) => a - b);

        const entries = njSet.map(nj => {
            const point = { label: String(nj) };
            ioSet.forEach(io => {
                const row = data.find(r =>
                    Number(r.numjobs) === nj &&
                    Number(r.iodepth) === io &&
                    (r.direction || 'read').toLowerCase() === primaryDir
                );
                if (row) {
                    point[`iops_io${io}`] = row.iops || 0;
                    point[`bw_io${io}`] = Math.round((row.bw_kbs || 0) / 1024);
                }
            });
            return point;
        });

        return { chartData: entries, ioDepths: ioSet, direction: primaryDir };
    }, [data]);

    // Select all iodepths by default when data changes
    useEffect(() => {
        setSelectedIoDepths(new Set(ioDepths));
    }, [ioDepths]);

    const toggleIoDepth = (io) => {
        setSelectedIoDepths(prev => {
            const next = new Set(prev);
            if (next.has(io)) {
                // Don't allow deselecting all
                if (next.size > 1) next.delete(io);
            } else {
                next.add(io);
            }
            return next;
        });
    };

    const selectAll = () => setSelectedIoDepths(new Set(ioDepths));

    if (!data || data.length === 0) {
        return (
            <div className="empty-state">
                <div className="empty-state-icon">📊</div>
                <div className="empty-state-text">Select a result set and test type to view charts</div>
            </div>
        );
    }

    const visibleIoDepths = ioDepths.filter(io => selectedIoDepths.has(io));

    return (
        <>
            {/* IO Depth multi-select */}
            <div className="card filter-bar" style={{ marginBottom: 'var(--space-md)' }}>
                <div className="filter-bar-inner">
                    <div className="filter-label">📐 I/O Depth</div>
                    <div className="filter-pills">
                        {ioDepths.map(io => (
                            <button
                                key={io}
                                className={`filter-pill${selectedIoDepths.has(io) ? ' active' : ''}`}
                                onClick={() => toggleIoDepth(io)}
                            >
                                io={io}
                            </button>
                        ))}
                        <button
                            className="filter-pill compare"
                            onClick={selectAll}
                            style={{ marginLeft: '4px' }}
                        >
                            All
                        </button>
                    </div>
                </div>
            </div>

            <div className="grid-2" style={{ marginBottom: 'var(--space-lg)' }}>
                {/* IOPS Chart */}
                <div className="card">
                    <div className="card-header">
                        <div>
                            <div className="card-title">⚡ IOPS ({direction})</div>
                            <div className="card-subtitle">Each line = I/O depth · X-axis = numjobs</div>
                        </div>
                    </div>
                    <ResponsiveContainer width="100%" height={340}>
                        <LineChart data={chartData} margin={{ top: 5, right: 20, bottom: 30, left: 10 }}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="label"
                                tick={{ fontSize: 11, fill: 'var(--text-muted)' }}
                                label={{ value: 'numjobs', position: 'insideBottom', offset: -5, style: { fill: 'var(--text-muted)', fontSize: '0.78rem' } }}
                            />
                            <YAxis tick={{ fontSize: 11 }} />
                            <Tooltip content={<CustomTooltip />} />
                            <Legend />
                            {visibleIoDepths.map((io) => (
                                <Line
                                    key={io}
                                    type="monotone"
                                    dataKey={`iops_io${io}`}
                                    name={`io=${io}`}
                                    stroke={IO_COLORS[ioDepths.indexOf(io) % IO_COLORS.length]}
                                    strokeWidth={2}
                                    dot={{ r: 3 }}
                                    activeDot={{ r: 5 }}
                                    connectNulls
                                />
                            ))}
                        </LineChart>
                    </ResponsiveContainer>
                </div>

                {/* Throughput Chart */}
                <div className="card">
                    <div className="card-header">
                        <div>
                            <div className="card-title">📈 Bandwidth — MB/s ({direction})</div>
                            <div className="card-subtitle">Each line = I/O depth · X-axis = numjobs</div>
                        </div>
                    </div>
                    <ResponsiveContainer width="100%" height={340}>
                        <LineChart data={chartData} margin={{ top: 5, right: 20, bottom: 30, left: 10 }}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="label"
                                tick={{ fontSize: 11, fill: 'var(--text-muted)' }}
                                label={{ value: 'numjobs', position: 'insideBottom', offset: -5, style: { fill: 'var(--text-muted)', fontSize: '0.78rem' } }}
                            />
                            <YAxis tick={{ fontSize: 11 }} />
                            <Tooltip content={<CustomTooltip />} />
                            <Legend />
                            {visibleIoDepths.map((io) => (
                                <Line
                                    key={io}
                                    type="monotone"
                                    dataKey={`bw_io${io}`}
                                    name={`io=${io}`}
                                    stroke={IO_COLORS[ioDepths.indexOf(io) % IO_COLORS.length]}
                                    strokeWidth={2}
                                    dot={{ r: 3 }}
                                    activeDot={{ r: 5 }}
                                    connectNulls
                                />
                            ))}
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>
        </>
    );
}
