// =============================================================
// Cedar Policies for Data Platform Gateway
// =============================================================
// Cedar uses default-deny: if no permit matches, the request is denied.
// A forbid statement always overrides a permit.
// =============================================================

// ----- ADMIN ROLE -----
// Admins can invoke any tool on the gateway (full access).
permit(
  principal in Group::"admins",
  action == Action::"InvokeTool",
  resource
);

// ----- ENGINEERING ROLE -----
// Engineers can run queries and describe/list tables.
permit(
  principal in Group::"engineering",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___run_query"
);

permit(
  principal in Group::"engineering",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___list_tables"
);

permit(
  principal in Group::"engineering",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___describe_table"
);

// Explicitly forbid engineers from deleting records, even if a
// broader permit is accidentally added later.
forbid(
  principal in Group::"engineering",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___delete_records"
);

// ----- MARKETING ROLE -----
// Marketing can only list and describe tables (read metadata).
permit(
  principal in Group::"marketing",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___list_tables"
);

permit(
  principal in Group::"marketing",
  action == Action::"InvokeTool",
  resource == Tool::"DatabaseTools___describe_table"
);
