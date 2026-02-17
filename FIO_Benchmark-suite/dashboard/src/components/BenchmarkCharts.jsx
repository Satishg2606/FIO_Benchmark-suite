import React, { useMemo } from 'react';
import {
    BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
    ResponsiveContainer
} from 'recharts';

const COLORS = {
    read: '#10b981',
    write: '#f43f5e',
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
            <div style={{ color: 'var(--text-muted)', marginBottom: 4 }}>{label}</div>
            {payload.map((entry, i) => (
                <div key={i} style={{ color: entry.color, marginTop: 2 }}>
                    {entry.name}: <strong>{Number(entry.value).toLocaleString()}</strong>
                </div>
            ))}
        </div>
    );
};

export default function BenchmarkCharts({ data }) {
    const { iopsData, bwData } = useMemo(() => {
        if (!data || data.length === 0) return { iopsData: [], bwData: [] };

        // Group by test_type, then split by direction
        const grouped = {};
        data.forEach(row => {
            const key = `${row.test_type}-${row.block_size}-nj${row.numjobs}-io${row.iodepth}`;
            if (!grouped[key]) grouped[key] = { label: key };
            const dir = (row.direction || 'read').toLowerCase();
            grouped[key][`iops_${dir}`] = row.iops || 0;
            grouped[key][`bw_${dir}`] = Math.round((row.bw_kbs || 0) / 1024); // convert to MB/s
        });

        const entries = Object.values(grouped);
        return { iopsData: entries, bwData: entries };
    }, [data]);

    if (!data || data.length === 0) {
        return (
            <div className="empty-state">
                <div className="empty-state-icon">📊</div>
                <div className="empty-state-text">Select a result set to view charts</div>
            </div>
        );
    }

    return (
        <div className="grid-2" style={{ marginBottom: 'var(--space-lg)' }}>
            {/* IOPS Chart */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">⚡ IOPS</div>
                </div>
                <ResponsiveContainer width="100%" height={320}>
                    <BarChart data={iopsData} margin={{ top: 5, right: 20, bottom: 60, left: 10 }}>
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
                        <Bar dataKey="iops_read" name="Read IOPS" fill={COLORS.read} radius={[4, 4, 0, 0]} />
                        <Bar dataKey="iops_write" name="Write IOPS" fill={COLORS.write} radius={[4, 4, 0, 0]} />
                    </BarChart>
                </ResponsiveContainer>
            </div>

            {/* Throughput Chart */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">📈 Throughput (MB/s)</div>
                </div>
                <ResponsiveContainer width="100%" height={320}>
                    <BarChart data={bwData} margin={{ top: 5, right: 20, bottom: 60, left: 10 }}>
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
                        <Bar dataKey="bw_read" name="Read MB/s" fill="#3b82f6" radius={[4, 4, 0, 0]} />
                        <Bar dataKey="bw_write" name="Write MB/s" fill="#8b5cf6" radius={[4, 4, 0, 0]} />
                    </BarChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
}
