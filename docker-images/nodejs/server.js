/**
 * Node.js Frontend Application for Stage4-v1 Deployment
 * Serves as the public-facing frontend that communicates with FastAPI backend
 */

const express = require('express');
const axios = require('axios');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Get FastAPI backend URL from environment
const FASTAPI_URL = process.env.FASTAPI_URL || 'http://localhost:8000';

console.log('🚀 Starting Node.js application...');
console.log(`📡 FastAPI URL: ${FASTAPI_URL}`);
console.log(`🌐 Port: ${PORT}`);

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Axios instance for FastAPI communication
const fastapiClient = axios.create({
    baseURL: FASTAPI_URL,
    timeout: 30000, // 30 second timeout
    headers: {
        'Content-Type': 'application/json',
    }
});

// Add request interceptor for logging
fastapiClient.interceptors.request.use(request => {
    console.log(`🔄 FastAPI Request: ${request.method.toUpperCase()} ${request.url}`);
    return request;
});

// Add response interceptor for logging
fastapiClient.interceptors.response.use(
    response => {
        console.log(`✅ FastAPI Response: ${response.status} ${response.config.url}`);
        return response;
    },
    error => {
        console.error(`❌ FastAPI Error: ${error.message} - ${error.config?.url}`);
        return Promise.reject(error);
    }
);

/**
 * Helper function to make FastAPI requests with error handling
 */
async function callFastAPI(endpoint, method = 'GET', data = null) {
    try {
        const response = await fastapiClient({
            method,
            url: endpoint,
            data
        });
        return {
            success: true,
            data: response.data,
            status: response.status
        };
    } catch (error) {
        console.error(`FastAPI call failed for ${endpoint}:`, error.message);
        
        if (error.response) {
            return {
                success: false,
                error: error.response.data,
                status: error.response.status,
                message: `FastAPI returned ${error.response.status}`
            };
        } else if (error.request) {
            return {
                success: false,
                error: 'No response from FastAPI service',
                status: 503,
                message: 'FastAPI service unavailable'
            };
        } else {
            return {
                success: false,
                error: error.message,
                status: 500,
                message: 'Internal request error'
            };
        }
    }
}

// Root endpoint - serves main page
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Health check endpoint for ALB
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        service: 'nodejs-frontend',
        timestamp: new Date().toISOString(),
        fastapi_url: FASTAPI_URL,
        port: PORT
    });
});

// Status endpoint - includes backend connectivity
app.get('/api/status', async (req, res) => {
    console.log('📊 Status check requested');
    
    const response = {
        frontend: {
            status: 'running',
            service: 'nodejs-frontend',
            timestamp: new Date().toISOString(),
            fastapi_url: FASTAPI_URL
        },
        backend: {
            status: 'unknown',
            database_connected: false,
            error: null
        }
    };
    
    // Try to get backend status
    const backendResult = await callFastAPI('/status');
    
    if (backendResult.success) {
        response.backend = {
            status: 'running',
            database_connected: backendResult.data.database_connected || false,
            database_error: backendResult.data.database_error || null,
            service: backendResult.data.service || 'fastapi-backend',
            environment: backendResult.data.environment || 'unknown'
        };
    } else {
        response.backend = {
            status: 'error',
            database_connected: false,
            error: backendResult.message,
            details: backendResult.error
        };
    }
    
    console.log(`📊 Status response - Backend: ${response.backend.status}, DB: ${response.backend.database_connected}`);
    res.json(response);
});

// Database test endpoint - proxy to FastAPI
app.get('/api/db-test', async (req, res) => {
    console.log('🔍 Database test requested');
    
    const backendResult = await callFastAPI('/db-test');
    
    const response = {
        frontend_status: 'ok',
        backend_response: null,
        success: backendResult.success
    };
    
    if (backendResult.success) {
        response.backend_response = backendResult.data;
        console.log('✅ Database test successful');
    } else {
        response.backend_response = {
            error: backendResult.message,
            details: backendResult.error,
            status: backendResult.status
        };
        console.log('❌ Database test failed');
    }
    
    // Return appropriate HTTP status
    const statusCode = backendResult.success ? 200 : (backendResult.status || 500);
    res.status(statusCode).json(response);
});

// FastAPI root endpoint proxy
app.get('/api/fastapi', async (req, res) => {
    console.log('🔗 FastAPI root endpoint requested');
    
    const backendResult = await callFastAPI('/');
    
    if (backendResult.success) {
        res.json({
            frontend_message: 'Request proxied from Node.js frontend',
            backend_response: backendResult.data
        });
    } else {
        res.status(backendResult.status || 500).json({
            error: 'Failed to connect to FastAPI backend',
            details: backendResult.error
        });
    }
});

// Configuration endpoint - shows current configuration
app.get('/api/config', async (req, res) => {
    console.log('⚙️ Configuration requested');
    
    const frontendConfig = {
        service: 'nodejs-frontend',
        port: PORT,
        fastapi_url: FASTAPI_URL,
        environment: process.env.NODE_ENV || 'production',
        timestamp: new Date().toISOString()
    };
    
    // Try to get backend configuration
    const backendResult = await callFastAPI('/config');
    
    const response = {
        frontend: frontendConfig,
        backend: backendResult.success ? backendResult.data : {
            error: 'Unable to fetch backend configuration',
            details: backendResult.error
        }
    };
    
    res.json(response);
});

// Environment info endpoint
app.get('/api/environment', async (req, res) => {
    console.log('🌍 Environment info requested');
    
    const frontendEnv = {
        NODE_ENV: process.env.NODE_ENV || 'production',
        PORT: PORT,
        FASTAPI_URL: FASTAPI_URL,
        service: 'nodejs-frontend'
    };
    
    // Try to get backend environment
    const backendResult = await callFastAPI('/environment');
    
    const response = {
        frontend: frontendEnv,
        backend: backendResult.success ? backendResult.data : {
            error: 'Unable to fetch backend environment',
            details: backendResult.error
        }
    };
    
    res.json(response);
});

// Catch-all for API routes that don't exist
app.get('/api/*', (req, res) => {
    res.status(404).json({
        error: 'API endpoint not found',
        path: req.path,
        available_endpoints: [
            '/api/status',
            '/api/db-test',
            '/api/fastapi',
            '/api/config',
            '/api/environment'
        ]
    });
});

// Global error handler
app.use((err, req, res, next) => {
    console.error('🚨 Unhandled error:', err);
    res.status(500).json({
        error: 'Internal server error',
        message: err.message,
        service: 'nodejs-frontend'
    });
});

// 404 handler for non-API routes (serve index.html for SPA routing)
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
    console.log(`✅ Node.js application running on port ${PORT}`);
    console.log(`🔗 FastAPI Backend URL: ${FASTAPI_URL}`);
    console.log('📝 Available endpoints:');
    console.log('   GET  /              - Main page');
    console.log('   GET  /health        - Health check');
    console.log('   GET  /api/status    - Full status including DB');
    console.log('   GET  /api/db-test   - Database test');
    console.log('   GET  /api/fastapi   - FastAPI root proxy');
    console.log('   GET  /api/config    - Configuration info');
    console.log('   GET  /api/environment - Environment info');
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('🛑 SIGTERM received, shutting down gracefully');
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('🛑 SIGINT received, shutting down gracefully');
    process.exit(0);
});

module.exports = app;