import React, { useState, useEffect, useRef } from 'react';
import {
    LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip,
    ResponsiveContainer
} from 'recharts';

const MAX_POINTS = 60; // keep last 60 data points

const MiniSparkline = ({ data, dataKey, color, unit, label, value }) => (
    <div className="stat-card" style={{ minWidth: 0 }}>
        <div className="stat-label">{label}</div>
        <div className="stat-value">
            {value != null ? value : '—'}
            <span className="stat-unit">{unit}</span>
        </div>
        <div style={{ marginTop: 8, height: 50 }}>
            <ResponsiveContainer width="100%" height="100%">
                <LineChart data={data} margin={{ top: 2, right: 2, bottom: 2, left: 2 }}>
                    <Line
                        type="monotone"
                        dataKey={dataKey}
                        stroke={color}
                        strokeWidth={1.5}
                        dot={false}
                        isAnimationActive={false}
                    />
                </LineChart>
            </ResponsiveContainer>
        </div>
    </div>
);

export default function LiveTelemetry() {
    const [connected, setConnected] = useState(false);
    const [history, setHistory] = useState([]);
    const [latest, setLatest] = useState(null);
    const wsRef = useRef(null);

    useEffect(() => {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}/ws/telemetry`;

        const connect = () => {
            const ws = new WebSocket(wsUrl);
            wsRef.current = ws;

            ws.onopen = () => setConnected(true);
            ws.onclose = () => {
                setConnected(false);
                // Retry after 3s
                setTimeout(connect, 3000);
            };
            ws.onerror = () => ws.close();

            ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    setLatest(data);
                    setHistory(prev => {
                        const next = [...prev, data];
                        return next.length > MAX_POINTS ? next.slice(-MAX_POINTS) : next;
                    });
                } catch (e) {
                    // ignore
                }
            };
        };

        connect();

        return () => {
            if (wsRef.current) wsRef.current.close();
        };
    }, []);

    return (
        <div className="card">
            <div className="card-header">
                <div>
                    <div className="card-title" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        🖥 Live System Health
                        {connected ? (
                            <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: '0.75rem', color: 'var(--accent-emerald)' }}>
                                <span className="live-dot" /> Connected
                            </span>
                        ) : (
                            <span style={{ fontSize: '0.75rem', color: 'var(--accent-amber)' }}>
                                ⏳ Connecting...
                            </span>
                        )}
                    </div>
                    <div className="card-subtitle">
                        Real-time metrics from the server (updates every 1s)
                    </div>
                </div>
            </div>

            {!connected && history.length === 0 ? (
                <div className="empty-state">
                    <div className="empty-state-icon">📡</div>
                    <div className="empty-state-text">
                        Connecting to telemetry server...<br />
                        <span style={{ fontSize: '0.8rem' }}>
                            Make sure the API server is running: <code style={{ color: 'var(--accent-blue)' }}>uvicorn src.api_server:app --port 8000</code>
                        </span>
                    </div>
                </div>
            ) : (
                <div className="grid-3">
                    <MiniSparkline
                        data={history}
                        dataKey="cpu_pct"
                        color="#3b82f6"
                        unit="%"
                        label="CPU Usage"
                        value={latest?.cpu_pct}
                    />
                    <MiniSparkline
                        data={history}
                        dataKey="ram_pct"
                        color="#8b5cf6"
                        unit="%"
                        label="RAM Usage"
                        value={latest?.ram_pct}
                    />
                    <MiniSparkline
                        data={history}
                        dataKey="cpu_temp_c"
                        color="#f59e0b"
                        unit="°C"
                        label="CPU Temp"
                        value={latest?.cpu_temp_c}
                    />
                    <MiniSparkline
                        data={history}
                        dataKey="net_rx_mbs"
                        color="#10b981"
                        unit="MB/s"
                        label="Net ↓ RX"
                        value={latest?.net_rx_mbs}
                    />
                    <MiniSparkline
                        data={history}
                        dataKey="net_tx_mbs"
                        color="#06b6d4"
                        unit="MB/s"
                        label="Net ↑ TX"
                        value={latest?.net_tx_mbs}
                    />
                    <div className="stat-card">
                        <div className="stat-label">Server Status</div>
                        <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 4 }}>
                            <div style={{ fontSize: '0.82rem', color: 'var(--text-secondary)' }}>
                                Samples: <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--text-primary)' }}>{history.length}</span>
                            </div>
                            <div style={{ fontSize: '0.82rem', color: 'var(--text-secondary)' }}>
                                Last: <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--text-primary)', fontSize: '0.75rem' }}>
                                    {latest?.timestamp || '—'}
                                </span>
                            </div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
}
