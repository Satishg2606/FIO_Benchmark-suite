import React from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import Header from './components/Header';
import DashboardPage from './pages/DashboardPage';
import HistoryPage from './pages/HistoryPage';

export default function App() {
    return (
        <Router>
            <Header />
            <div className="app-container page-enter">
                <Routes>
                    <Route path="/" element={<DashboardPage />} />
                    <Route path="/history" element={<HistoryPage />} />
                </Routes>
            </div>
        </Router>
    );
}
