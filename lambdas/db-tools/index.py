"""
Database Tools Lambda — Backend for the DataPlatformGateway

This Lambda implements the actual tool logic that the gateway invokes.
For this demo, it uses mock data. In production, you'd connect to
RDS, Redshift, Athena, or whatever your data platform uses.

Tool dispatch is based on the tool name in the MCP request payload.
"""

import json

# ---- Mock data for demonstration ----

MOCK_DATABASES = {
    "analytics": {
        "users": {
            "columns": [
                {"name": "id", "type": "INTEGER", "nullable": False},
                {"name": "email", "type": "VARCHAR(255)", "nullable": False},
                {"name": "name", "type": "VARCHAR(128)", "nullable": True},
                {"name": "created_at", "type": "TIMESTAMP", "nullable": False},
                {"name": "team", "type": "VARCHAR(64)", "nullable": True},
            ],
            "row_count": 15420,
        },
        "events": {
            "columns": [
                {"name": "id", "type": "BIGINT", "nullable": False},
                {"name": "user_id", "type": "INTEGER", "nullable": False},
                {"name": "event_type", "type": "VARCHAR(64)", "nullable": False},
                {"name": "payload", "type": "JSONB", "nullable": True},
                {"name": "timestamp", "type": "TIMESTAMP", "nullable": False},
            ],
            "row_count": 2847103,
        },
        "campaigns": {
            "columns": [
                {"name": "id", "type": "INTEGER", "nullable": False},
                {"name": "name", "type": "VARCHAR(255)", "nullable": False},
                {"name": "status", "type": "VARCHAR(32)", "nullable": False},
                {"name": "budget", "type": "DECIMAL(10,2)", "nullable": True},
                {"name": "start_date", "type": "DATE", "nullable": True},
            ],
            "row_count": 342,
        },
    },
    "production": {
        "orders": {
            "columns": [
                {"name": "id", "type": "BIGINT", "nullable": False},
                {"name": "customer_id", "type": "INTEGER", "nullable": False},
                {"name": "total", "type": "DECIMAL(12,2)", "nullable": False},
                {"name": "status", "type": "VARCHAR(32)", "nullable": False},
                {"name": "created_at", "type": "TIMESTAMP", "nullable": False},
            ],
            "row_count": 891204,
        },
        "products": {
            "columns": [
                {"name": "id", "type": "INTEGER", "nullable": False},
                {"name": "sku", "type": "VARCHAR(64)", "nullable": False},
                {"name": "name", "type": "VARCHAR(255)", "nullable": False},
                {"name": "price", "type": "DECIMAL(10,2)", "nullable": False},
                {"name": "stock", "type": "INTEGER", "nullable": False},
            ],
            "row_count": 4521,
        },
    },
}


def handler(event, context):
    """
    The gateway sends tool invocations as JSON with:
    {
        "toolName": "run_query",
        "input": { ... tool arguments ... }
    }
    """
    try:
        body = json.loads(event.get("body", "{}"))
        tool_name = body.get("toolName", "")
        tool_input = body.get("input", {})

        if tool_name == "list_tables":
            return list_tables(tool_input)
        elif tool_name == "describe_table":
            return describe_table(tool_input)
        elif tool_name == "run_query":
            return run_query(tool_input)
        elif tool_name == "delete_records":
            return delete_records(tool_input)
        else:
            return error_response(400, f"Unknown tool: {tool_name}")

    except Exception as e:
        return error_response(500, f"Internal error: {str(e)}")


def list_tables(params):
    database = params.get("database")
    if not database:
        return error_response(400, "Missing required parameter: database")

    db = MOCK_DATABASES.get(database)
    if not db:
        return error_response(404, f"Database '{database}' not found. Available: {list(MOCK_DATABASES.keys())}")

    tables = [
        {"table_name": name, "row_count": info["row_count"]}
        for name, info in db.items()
    ]

    return success_response({
        "database": database,
        "tables": tables,
        "total_tables": len(tables),
    })


def describe_table(params):
    database = params.get("database")
    table = params.get("table")

    if not database or not table:
        return error_response(400, "Missing required parameters: database, table")

    db = MOCK_DATABASES.get(database)
    if not db:
        return error_response(404, f"Database '{database}' not found")

    table_info = db.get(table)
    if not table_info:
        return error_response(404, f"Table '{table}' not found in '{database}'. Available: {list(db.keys())}")

    return success_response({
        "database": database,
        "table": table,
        "columns": table_info["columns"],
        "row_count": table_info["row_count"],
    })


def run_query(params):
    sql = params.get("sql", "")
    database = params.get("database")

    if not database or not sql:
        return error_response(400, "Missing required parameters: sql, database")

    if database not in MOCK_DATABASES:
        return error_response(404, f"Database '{database}' not found")

    # Basic safety check (in production, use a proper SQL parser)
    sql_upper = sql.strip().upper()
    if not sql_upper.startswith("SELECT"):
        return error_response(400, "Only SELECT queries are allowed. Use delete_records for mutations.")

    # Return mock results
    return success_response({
        "database": database,
        "query": sql,
        "columns": ["id", "name", "value"],
        "rows": [
            [1, "example_row_1", 42],
            [2, "example_row_2", 87],
            [3, "example_row_3", 15],
        ],
        "row_count": 3,
        "execution_time_ms": 124,
        "note": "Mock results — connect to a real database for production use",
    })


def delete_records(params):
    table = params.get("table")
    condition = params.get("condition")
    database = params.get("database")

    if not all([table, condition, database]):
        return error_response(400, "Missing required parameters: table, condition, database")

    if database not in MOCK_DATABASES:
        return error_response(404, f"Database '{database}' not found")

    if table not in MOCK_DATABASES[database]:
        return error_response(404, f"Table '{table}' not found in '{database}'")

    # Mock deletion
    return success_response({
        "database": database,
        "table": table,
        "condition": condition,
        "deleted_count": 7,
        "note": "Mock deletion — no actual records were removed",
    })


def success_response(data):
    return {
        "statusCode": 200,
        "body": json.dumps(data),
    }


def error_response(status_code, message):
    return {
        "statusCode": status_code,
        "body": json.dumps({"error": message}),
    }
