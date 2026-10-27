import { href, redirect } from "react-router";
import type { Route } from "./+types/logout";
import { logout } from "~/lib/auth.server";
export function loader() { return redirect(href("/login")); }
export async function action({ request }: Route.ActionArgs) { return logout(request); }
