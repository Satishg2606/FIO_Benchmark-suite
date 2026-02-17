import React from 'react';

export default function HistoryTable({ results, onSelect, selectedName }) {
    if (!results || results.length === 0) {
        return (
            <div className="card">
                <div className="empty-state">
                    <div className="empty-state-icon">📂</div>
                    <div className="empty-state-text">
                        No parsed result sets found.<br />
                        Run the benchmark engine and result parser first.
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="card">
            <div className="card-header">
                <div className="card-title">📁 Available Result Sets</div>
            </div>
            <table className="data-table">
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>File</th>
                        <th>Size</th>
                        <th>Last Modified</th>
                        <th>Action</th>
                    </tr>
                </thead>
                <tbody>
                    {results.map(r => (
                        <tr
                            key={r.name}
                            style={selectedName === r.name ? { background: 'rgba(59,130,246,0.08)' } : {}}
                        >
                            <td style={{ color: 'var(--text-primary)', fontWeight: 500 }}>
                                {r.name}
                            </td>
                            <td>{r.filename}</td>
                            <td>{(r.size_bytes / 1024).toFixed(1)} KB</td>
                            <td>{new Date(r.modified).toLocaleString()}</td>
                            <td>
                                <button
                                    className={`btn ${selectedName === r.name ? 'btn-primary' : 'btn-secondary'}`}
                                    onClick={() => onSelect(r.name)}
                                    style={{ padding: '4px 12px', fontSize: '0.78rem' }}
                                >
                                    {selectedName === r.name ? '✓ Viewing' : 'View'}
                                </button>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}
