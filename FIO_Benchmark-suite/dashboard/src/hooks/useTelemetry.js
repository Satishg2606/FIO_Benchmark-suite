import { useState, useEffect } from 'react';

const API_BASE = '/api';

export function useTelemetrySessions() {
    const [sessions, setSessions] = useState([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetch(`${API_BASE}/telemetry`)
            .then(res => res.json())
            .then(json => setSessions(json.sessions || []))
            .catch(() => { })
            .finally(() => setLoading(false));
    }, []);

    return { sessions, loading };
}

export function useTelemetryData(sessionName) {
    const [data, setData] = useState(null);
    const [loading, setLoading] = useState(false);

    useEffect(() => {
        if (!sessionName) { setData(null); return; }
        setLoading(true);
        fetch(`${API_BASE}/telemetry/${encodeURIComponent(sessionName)}`)
            .then(res => res.json())
            .then(json => setData(json.data || []))
            .catch(() => { })
            .finally(() => setLoading(false));
    }, [sessionName]);

    return { data, loading };
}
