import { useState, useEffect, useCallback } from 'react';

const API_BASE = '/api';

export function useBenchmarkResults() {
    const [resultSets, setResultSets] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);

    const fetchResultSets = useCallback(async () => {
        setLoading(true);
        try {
            const res = await fetch(`${API_BASE}/results`);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const json = await res.json();
            setResultSets(json.results || []);
            setError(null);
        } catch (err) {
            setError(err.message);
        } finally {
            setLoading(false);
        }
    }, []);

    useEffect(() => { fetchResultSets(); }, [fetchResultSets]);

    return { resultSets, loading, error, refresh: fetchResultSets };
}

export function useResultData(name) {
    const [data, setData] = useState(null);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState(null);

    useEffect(() => {
        if (!name) {
            setData(null);
            return;
        }
        let cancelled = false;
        setLoading(true);

        fetch(`${API_BASE}/results/${encodeURIComponent(name)}`)
            .then(res => {
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                return res.json();
            })
            .then(json => {
                if (!cancelled) {
                    setData(json.data || []);
                    setError(null);
                }
            })
            .catch(err => {
                if (!cancelled) setError(err.message);
            })
            .finally(() => {
                if (!cancelled) setLoading(false);
            });

        return () => { cancelled = true; };
    }, [name]);

    return { data, loading, error };
}

export function useDisks() {
    const [disks, setDisks] = useState([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        fetch(`${API_BASE}/disks`)
            .then(res => res.json())
            .then(json => setDisks(json.disks || []))
            .catch(() => { })
            .finally(() => setLoading(false));
    }, []);

    return { disks, loading };
}
