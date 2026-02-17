import React from 'react';
import { Link, useLocation } from 'react-router-dom';

export default function Header() {
    const location = useLocation();

    return (
        <nav className="nav-bar">
            <Link to="/" className="nav-logo">
                <div className="nav-logo-icon">F</div>
                <div className="nav-logo-text">
                    FIO <span>Benchmark</span> Suite
                </div>
            </Link>
            <div className="nav-links">
                <Link
                    to="/"
                    className={`nav-link${location.pathname === '/' ? ' active' : ''}`}
                >
                    ⚡ Dashboard
                </Link>
                <Link
                    to="/history"
                    className={`nav-link${location.pathname === '/history' ? ' active' : ''}`}
                >
                    📊 History
                </Link>
            </div>
        </nav>
    );
}
