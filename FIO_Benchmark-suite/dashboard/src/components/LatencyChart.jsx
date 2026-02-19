import React, { useMemo, useState } from 'react';
import {
    XAxis, YAxis, CartesianGrid, Tooltip, Legend,
    ResponsiveContainer, Area, AreaChart
} from 'recharts';

const PERCENTILE_COLORS = {
    p50: '#10b981',
    p95: '#3b82f6',
    p99: '#8b5cf6',
    p999: '#f43f5e',
};

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
                    {entry.name}: <strong>{Number(entry.value).toLocaleString()} µs</strong>
                </div>
            ))}
        </div>
    );
};

export default function LatencyChart({ data }) {
    const [selectedIoDepth, setSelectedIoDepth] = useState('');

    // Get unique iodepth values
    const ioDepths = useMemo(() => {
        if (!data || data.length === 0) return [];
        return [...new Set(data.map(r => Number(r.iodepth) || 0))].sort((a, b) => a - b);
    }, [data]);

    // Auto-select first iodepth
    const activeIoDepth = useMemo(() => {
        const sel = Number(selectedIoDepth);
        if (sel && ioDepths.includes(sel)) return sel;
        return ioDepths[0] || 0;
    }, [selectedIoDepth, ioDepths]);

    const chartData = useMemo(() => {
        if (!data || data.length === 0 || !activeIoDepth) return [];

        // Filter to selected iodepth
        const filtered = data.filter(r => Number(r.iodepth) === activeIoDepth);

        // Get unique numjobs sorted
        const njSet = [...new Set(filtered.map(r => Number(r.numjobs) || 0))].sort((a, b) => a - b);

        return njSet.map(nj => {
            // Find the matching row (take the first/primary direction row)
            const row = filtered.find(r => Number(r.numjobs) === nj);
            return {
                label: String(nj),
                p50: row ? (row.lat_p50_us || 0) : 0,
                p95: row ? (row.lat_p95_us || 0) : 0,
                p99: row ? (row.lat_p99_us || 0) : 0,
                p999: row ? (row.lat_p999_us || 0) : 0,
                mean: row ? (row.lat_mean_us || 0) : 0,
            };
        });
    }, [data, activeIoDepth]);

    if (!data || data.length === 0 || chartData.length === 0) {
        return null;
    }

    return (
        <div className="card" style={{ marginBottom: 'var(--space-lg)' }}>
            <div className="card-header">
                <div>
                    <div className="card-title">⏱ Latency Distribution (µs)</div>
                    <div className="card-subtitle">Percentile breakdown per numjobs · Select I/O depth below</div>
                </div>
                <div className="filter-pills" style={{ marginLeft: 'auto' }}>
                    {ioDepths.map(io => (
                        <button
                            key={io}
                            className={`filter-pill${activeIoDepth === io ? ' active' : ''}`}
                            onClick={() => setSelectedIoDepth(String(io))}
                            style={{ padding: '4px 10px', fontSize: '0.75rem' }}
                        >
                            io={io}
                        </button>
                    ))}
                </div>
            </div>
            <ResponsiveContainer width="100%" height={360}>
                <AreaChart data={chartData} margin={{ top: 10, right: 20, bottom: 30, left: 10 }}>
                    <defs>
                        <linearGradient id="gradP50" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor={PERCENTILE_COLORS.p50} stopOpacity={0.3} />
                            <stop offset="95%" stopColor={PERCENTILE_COLORS.p50} stopOpacity={0} />
                        </linearGradient>
                        <linearGradient id="gradP95" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor={PERCENTILE_COLORS.p95} stopOpacity={0.3} />
                            <stop offset="95%" stopColor={PERCENTILE_COLORS.p95} stopOpacity={0} />
                        </linearGradient>
                        <linearGradient id="gradP99" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor={PERCENTILE_COLORS.p99} stopOpacity={0.3} />
                            <stop offset="95%" stopColor={PERCENTILE_COLORS.p99} stopOpacity={0} />
                        </linearGradient>
                        <linearGradient id="gradP999" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor={PERCENTILE_COLORS.p999} stopOpacity={0.3} />
                            <stop offset="95%" stopColor={PERCENTILE_COLORS.p999} stopOpacity={0} />
                        </linearGradient>
                    </defs>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis
                        dataKey="label"
                        tick={{ fontSize: 11, fill: 'var(--text-muted)' }}
                        label={{ value: 'numjobs', position: 'insideBottom', offset: -5, style: { fill: 'var(--text-muted)', fontSize: '0.78rem' } }}
                    />
                    <YAxis
                        tick={{ fontSize: 11 }}
                        label={{ value: 'µs', angle: -90, position: 'insideLeft', style: { fill: 'var(--text-muted)' } }}
                    />
                    <Tooltip content={<CustomTooltip />} />
                    <Legend />
                    <Area type="monotone" dataKey="p999" name="p99.9" stroke={PERCENTILE_COLORS.p999} fill="url(#gradP999)" strokeWidth={2} />
                    <Area type="monotone" dataKey="p99" name="p99" stroke={PERCENTILE_COLORS.p99} fill="url(#gradP99)" strokeWidth={2} />
                    <Area type="monotone" dataKey="p95" name="p95" stroke={PERCENTILE_COLORS.p95} fill="url(#gradP95)" strokeWidth={2} />
                    <Area type="monotone" dataKey="p50" name="p50" stroke={PERCENTILE_COLORS.p50} fill="url(#gradP50)" strokeWidth={2} />
                </AreaChart>
            </ResponsiveContainer>
        </div>
    );
}
