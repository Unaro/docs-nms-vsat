import { type RouteConfig, index, layout, route } from "@react-router/dev/routes";

export default [
  index("routes/index.tsx"),
  route("login", "routes/login.tsx"),
  route("register", "routes/register.tsx"),
  route("logout", "routes/logout.tsx"),
  route("api/telemetry/stream", "routes/api.telemetry.stream.ts"),
  layout("routes/_protected.tsx", [
    route("profile", "routes/profile.tsx"),
    route("dashboard", "routes/dashboard.tsx"),
    route("dashboard/nodes/:id", "routes/dashboard.nodes.$id.tsx"),
    route("dashboard/templates", "routes/dashboard.templates.tsx"),
    route("dashboard/templates/:id", "routes/dashboard.templates.$id.tsx"),
    route("dashboard/credentials", "routes/dashboard.credentials.tsx"),
  ]),
] satisfies RouteConfig;