import { href, redirect } from "react-router";
import type { Route } from "./+types/index";
import { currentUser } from "~/lib/auth.server";
export async function loader({ request }: Route.LoaderArgs) {
  return redirect(await currentUser(request) ? href("/profile") : href("/login"));
}
export default function IndexPage() { return null; }
