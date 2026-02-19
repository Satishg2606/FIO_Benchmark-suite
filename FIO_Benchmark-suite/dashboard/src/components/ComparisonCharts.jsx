import React, { useMemo } from 'react';
import {
    LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
    ResponsiveContainer
} from 'recharts';

const TEST_TYPE_COLORS = {
    seqread: '#10b981',
    seqwrite: '#3b82f6',
    randread: '#f59e0b',
    randwrite: '#f43f5e',
    randrw: '#8b5cf6',
};

const TEST_TYPE_LABELS = {
    seqread: 'Seq Read',
    seqwrite: 'Seq Write',
    randread: 'Rand Read',
    randwrite: 'Rand Write',
    randrw: 'Rand R/W',
};

function blockSizeToBytes(bs) {
    const m = String(bs).toLowerCase().match(/^(\d+)(k|m|g)?$/);
    if (!m) return 0;
    const v = parseInt(m[1], 10);
    const s = m[2] || '';
    if (s === 'k') return v * 1024;
    if (s === 'm') return v * 1024 * 1024;
    if (s === 'g') return v * 1024 * 1024 * 1024;
    return v;
}

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
            <div style={{ color: 'var(--text-muted)', marginBottom: 4 }}>{label}</div>
            {payload.map((entry, i) => (
                <div key={i} style={{ color: entry.color, marginTop: 2 }}>
                    {entry.name}: <strong>{Number(entry.value).toLocaleString()}</strong>
                </div>
            ))}
        </div>
    );
};

export default function ComparisonCharts({ data }) {
    const { chartData, testTypes } = useMemo(() => {
        if (!data || data.length === 0) return { chartData: [], testTypes: [] };

        const types = [...new Set(data.map(r => r.test_type))];

        // Build a map: xKey -> { label, type1_iops, type1_bw, ... }
        const xKeySet = new Set();
        const grouped = {};

        data.forEach(row => {
            const nj = Number(row.numjobs) || 0;
            const io = Number(row.iodepth) || 0;
            const bs = blockSizeToBytes(row.block_size);
            const xKey = `${row.block_size}-nj${nj}-io${io}`;
            const sortKey = bs * 1e12 + nj * 1e6 + io;

            if (!grouped[xKey]) {
                grouped[xKey] = { label: xKey, _sortKey: sortKey };
            }
            xKeySet.add(xKey);

            const tt = row.test_type;
            const dir = (row.direction || 'read').toLowerCase();
            // For IOPS/BW, take the primary direction value (read for read tests, write for write tests)
            const iopsKey = `${tt}_iops`;
            const bwKey = `${tt}_bw`;

            // Accumulate — for randrw we get both read and write, use the read value for comparison
            if (dir === 'read' || !grouped[xKey][iopsKey]) {
                grouped[xKey][iopsKey] = row.iops || 0;
                grouped[xKey][bwKey] = Math.round((row.bw_kbs || 0) / 1024);
            }
        });

        const entries = Object.values(grouped).sort((a, b) => a._sortKey - b._sortKey);
        return { chartData: entries, testTypes: types };
    }, [data]);

    if (chartData.length === 0) {
        return (
            <div className="empty-state">
                <div className="empty-state-icon">📊</div>
                <div className="empty-state-text">No data available for comparison</div>
            </div>
        );
    }

    return (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-lg)' }}>
            {/* IOPS Comparison */}
            <div className="card">
                <div className="card-header">
                    <div>
                        <div className="card-title">⚡ IOPS — All Test Types</div>
                        <div className="card-subtitle">Compare IOPS across all test types</div>
                    </div>
                </div>
                <ResponsiveContainer width="100%" height={380}>
                    <LineChart data={chartData} margin={{ top: 5, right: 20, bottom: 60, left: 10 }}>
                        <CartesianGrid strokeDasharray="3 3" />
                        <XAxis
                            dataKey="label"
                            tick={{ fontSize: 10, fill: 'var(--text-muted)' }}
                            angle={-30}
                            textAnchor="end"
                            height={80}
                        />
                        <YAxis tick={{ fontSize: 11 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Legend />
                        {testTypes.map(tt => (
                            <Line
                                key={tt}
                                type="monotone"
                                dataKey={`${tt}_iops`}
                                name={TEST_TYPE_LABELS[tt] || tt}
                                stroke={TEST_TYPE_COLORS[tt] || '#9ca3af'}
                                strokeWidth={2}
                                dot={{ r: 3 }}
                                activeDot={{ r: 5 }}
                                connectNulls
                            />
                        ))}
                    </LineChart>
                </ResponsiveContainer>
            </div>

            {/* BW Comparison */}
            <div className="card">
                <div className="card-header">
                    <div>
                        <div className="card-title">📈 Bandwidth (MB/s) — All Test Types</div>
                        <div className="card-subtitle">Compare throughput across all test types</div>
                    </div>
                </div>
                <ResponsiveContainer width="100%" height={380}>
                    <LineChart data={chartData} margin={{ top: 5, right: 20, bottom: 60, left: 10 }}>
                        <CartesianGrid strokeDasharray="3 3" />
                        <XAxis
                            dataKey="label"
                            tick={{ fontSize: 10, fill: 'var(--text-muted)' }}
                            angle={-30}
                            textAnchor="end"
                            height={80}
                        />
                        <YAxis tick={{ fontSize: 11 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Legend />
                        {testTypes.map(tt => (
                            <Line
                                key={tt}
                                type="monotone"
                                dataKey={`${tt}_bw`}
                                name={TEST_TYPE_LABELS[tt] || tt}
                                stroke={TEST_TYPE_COLORS[tt] || '#9ca3af'}
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
    );
}
