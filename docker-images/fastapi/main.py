"""
FastAPI Application for Stage4-v1 Deployment
PRE-CORRECTED: Proper RDS secret handling for username/password only structure
"""

import json
import logging
import os
from typing import Dict, Any, Optional
from contextlib import asynccontextmanager

import psycopg2
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Global database connection
db_connection = None

class DatabaseManager:
    """PRE-CORRECTED: Database manager with proper RDS secret structure handling"""
    
    def __init__(self):
        self.connection = None
        
    def get_connection_params(self) -> Dict[str, Any]:
        """
        PRE-CORRECTED: Extract connection parameters from RDS managed secret
        RDS secrets contain only username and password, not host/port/database
        """
        try:
            # Get database connection parameters from environment variables
            database_host = os.getenv("DATABASE_HOST")
            database_name = os.getenv("DATABASE_NAME", "postgres")
            database_port = int(os.getenv("DATABASE_PORT", "5432"))
            
            # Get secret from Kubernetes injection - contains JSON with username/password only
            database_secret = os.getenv("DATABASE_URL", "")
            
            if not database_secret:
                raise ValueError("DATABASE_URL secret not available from Kubernetes")
            
            if not database_host:
                raise ValueError("DATABASE_HOST not available from environment")
                
            logger.info(f"Database host: {database_host}")
            logger.info(f"Database name: {database_name}")
            logger.info(f"Database port: {database_port}")
            
            # PRE-CORRECTED: Parse RDS-generated secret (username/password only)
            try:
                secret = json.loads(database_secret)
                logger.info("Successfully parsed database secret JSON")
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse DATABASE_URL as JSON: {e}")
                logger.error(f"DATABASE_URL content (first 50 chars): {database_secret[:50]}...")
                raise ValueError(f"Invalid JSON in DATABASE_URL secret: {e}")
            
            # Validate secret structure
            if 'username' not in secret:
                raise ValueError("Secret missing required 'username' field")
            if 'password' not in secret:
                raise ValueError("Secret missing required 'password' field")
                
            logger.info(f"Secret contains username: {secret['username']}")
            
            # PRE-CORRECTED: Construct complete connection parameters
            # RDS secrets only contain username and password
            # We must provide host, port, and database name from environment
            return {
                "host": database_host,
                "database": database_name,
                "user": secret['username'],
                "password": secret['password'],
                "port": database_port,
                "connect_timeout": 10,
                "application_name": "fastapi-stage4v1"
            }
            
        except Exception as e:
            logger.error(f"Failed to get connection parameters: {e}")
            raise
    
    def connect(self) -> bool:
        """Establish database connection with proper error handling"""
        try:
            if self.connection and not self.connection.closed:
                logger.info("Database connection already exists and is healthy")
                return True
                
            logger.info("Establishing database connection...")
            conn_params = self.get_connection_params()
            
            # PRE-CORRECTED: Connection with proper parameters
            self.connection = psycopg2.connect(**conn_params)
            self.connection.autocommit = True
            
            # Test connection
            cursor = self.connection.cursor()
            cursor.execute("SELECT 1")
            result = cursor.fetchone()
            cursor.close()
            
            if result and result[0] == 1:
                logger.info("✅ Database connection successful")
                return True
            else:
                logger.error("Database connection test failed")
                return False
                
        except psycopg2.OperationalError as e:
            logger.error(f"Database connection failed - OperationalError: {e}")
            self.connection = None
            return False
        except psycopg2.Error as e:
            logger.error(f"Database connection failed - PostgreSQL Error: {e}")
            self.connection = None
            return False
        except Exception as e:
            logger.error(f"Database connection failed - Unexpected error: {e}")
            self.connection = None
            return False
    
    def is_connected(self) -> bool:
        """Check if database connection is active"""
        try:
            if not self.connection or self.connection.closed:
                return False
            
            cursor = self.connection.cursor()
            cursor.execute("SELECT 1")
            cursor.fetchone()
            cursor.close()
            return True
        except Exception as e:
            logger.error(f"Connection check failed: {e}")
            return False
    
    def execute_query(self, query: str, params: tuple = None) -> Optional[list]:
        """Execute a database query safely"""
        try:
            if not self.is_connected():
                logger.info("Connection lost, attempting to reconnect...")
                if not self.connect():
                    raise psycopg2.OperationalError("Failed to reconnect to database")
            
            cursor = self.connection.cursor()
            cursor.execute(query, params)
            
            # For SELECT queries, fetch results
            if query.strip().upper().startswith('SELECT'):
                results = cursor.fetchall()
                cursor.close()
                return results
            else:
                cursor.close()
                return None
                
        except Exception as e:
            logger.error(f"Query execution failed: {e}")
            raise
    
    def close(self):
        """Close database connection"""
        if self.connection and not self.connection.closed:
            self.connection.close()
            logger.info("Database connection closed")

# Initialize database manager
db_manager = DatabaseManager()

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application startup and shutdown events"""
    # Startup
    logger.info("🚀 FastAPI application starting up...")
    logger.info("Attempting database connection...")
    
    try:
        if db_manager.connect():
            logger.info("✅ Database connection established during startup")
        else:
            logger.warning("⚠️  Database connection failed during startup, will retry on first request")
    except Exception as e:
        logger.error(f"❌ Database connection error during startup: {e}")
    
    yield
    
    # Shutdown
    logger.info("FastAPI application shutting down...")
    db_manager.close()

# Initialize FastAPI application
app = FastAPI(
    title="Agentic AWS Stage4-v1 FastAPI Backend",
    description="Backend API service with PostgreSQL database connectivity",
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    """Root endpoint with basic service information"""
    return {
        "message": "Agentic AWS Stage4-v1 FastAPI Backend",
        "status": "running",
        "version": "1.0.0",
        "environment": os.getenv("ENVIRONMENT", "unknown")
    }

@app.get("/health")
async def health_check():
    """Health check endpoint for load balancer"""
    return {
        "status": "healthy",
        "timestamp": "2025-09-11",
        "service": "fastapi-backend"
    }

@app.get("/status")
async def status_check():
    """Comprehensive status check including database connectivity"""
    database_connected = False
    database_error = None
    
    try:
        # PRE-CORRECTED: Test database connection
        if db_manager.connect():
            database_connected = True
            logger.info("Status check: Database connection successful")
        else:
            database_error = "Failed to establish database connection"
            logger.warning("Status check: Database connection failed")
    except Exception as e:
        database_error = str(e)
        logger.error(f"Status check: Database connection error: {e}")
    
    return {
        "status": "running",
        "database_connected": database_connected,
        "database_error": database_error,
        "timestamp": "2025-09-11",
        "service": "fastapi-backend",
        "environment": os.getenv("ENVIRONMENT", "stage4-v1")
    }

@app.get("/db-test")
async def database_test():
    """
    PRE-CORRECTED: Database test endpoint with comprehensive operations
    Tests CREATE, INSERT, SELECT, and DROP operations
    """
    try:
        # Ensure database connection
        if not db_manager.connect():
            raise HTTPException(
                status_code=503,
                detail="Database connection failed"
            )
        
        results = []
        
        # Test 1: Create test table
        logger.info("DB Test: Creating test table...")
        db_manager.execute_query("""
            CREATE TABLE IF NOT EXISTS stage4v1_test (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100),
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        results.append("✅ Table created successfully")
        
        # Test 2: Insert test data
        logger.info("DB Test: Inserting test data...")
        db_manager.execute_query(
            "INSERT INTO stage4v1_test (name) VALUES (%s)",
            ("Stage4-v1 Test Record",)
        )
        results.append("✅ Data inserted successfully")
        
        # Test 3: Select test data
        logger.info("DB Test: Selecting test data...")
        rows = db_manager.execute_query("SELECT * FROM stage4v1_test ORDER BY id DESC LIMIT 5")
        results.append(f"✅ Data selected successfully: {len(rows)} rows retrieved")
        
        # Test 4: Clean up test table
        logger.info("DB Test: Cleaning up test table...")
        db_manager.execute_query("DROP TABLE IF EXISTS stage4v1_test")
        results.append("✅ Table dropped successfully")
        
        logger.info("DB Test: All database operations completed successfully")
        
        return {
            "status": "success",
            "database_connected": True,
            "test_results": results,
            "message": "All database operations completed successfully",
            "timestamp": "2025-09-11",
            "service": "fastapi-backend"
        }
        
    except psycopg2.Error as e:
        logger.error(f"Database test failed - PostgreSQL Error: {e}")
        raise HTTPException(
            status_code=503,
            detail={
                "error": "Database operation failed",
                "type": "PostgreSQL Error",
                "message": str(e),
                "database_connected": False
            }
        )
    except Exception as e:
        logger.error(f"Database test failed - Unexpected error: {e}")
        raise HTTPException(
            status_code=500,
            detail={
                "error": "Database test failed",
                "type": "Internal Server Error",
                "message": str(e),
                "database_connected": False
            }
        )

@app.get("/config")
async def config_info():
    """Configuration information endpoint (non-sensitive data only)"""
    return {
        "database_host": os.getenv("DATABASE_HOST", "not-configured"),
        "database_name": os.getenv("DATABASE_NAME", "not-configured"),
        "database_port": os.getenv("DATABASE_PORT", "not-configured"),
        "secret_configured": bool(os.getenv("DATABASE_URL")),
        "environment": os.getenv("ENVIRONMENT", "unknown"),
        "service": "fastapi-backend"
    }

@app.get("/environment")
async def environment_info():
    """Environment information endpoint"""
    return {
        "environment_vars": {
            "DATABASE_HOST": os.getenv("DATABASE_HOST", "not-set"),
            "DATABASE_NAME": os.getenv("DATABASE_NAME", "not-set"),
            "DATABASE_PORT": os.getenv("DATABASE_PORT", "not-set"),
            "DATABASE_URL_SET": "Yes" if os.getenv("DATABASE_URL") else "No",
        },
        "service": "fastapi-backend",
        "timestamp": "2025-09-11"
    }

if __name__ == "__main__":
    # For local development
    logger.info("Starting FastAPI application in development mode...")
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )