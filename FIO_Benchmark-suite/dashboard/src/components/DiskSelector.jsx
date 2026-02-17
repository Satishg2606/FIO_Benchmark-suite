import React from 'react';

export default function DiskSelector({ disks, selected, onChange, loading }) {
    return (
        <div className="card" style={{ marginBottom: 'var(--space-lg)' }}>
            <div className="card-header">
                <div>
                    <div className="card-title">🖴 Disk Selection</div>
                    <div className="card-subtitle">
                        Choose a result set to visualize benchmark data
                    </div>
                </div>
            </div>
            <div className="select-wrapper">
                {loading ? (
                    <div className="loading-spinner" />
                ) : (
                    <select
                        className="select-input"
                        value={selected}
                        onChange={(e) => onChange(e.target.value)}
                        id="disk-selector"
                    >
                        <option value="">— Select a result set —</option>
                        {disks.map((d) => (
                            <option key={d.name} value={d.name}>
                                {d.name} ({d.filename} — {(d.size_bytes / 1024).toFixed(1)} KB)
                            </option>
                        ))}
                    </select>
                )}
            </div>
        </div>
    );
}
