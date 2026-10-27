import { href, redirect } from "react-router";
import { nmsApi } from "~/api";

export async function clientLoader() {
    try {
        const user = await nmsApi.currentUser();
        if (user) {
            throw redirect(href('/profile'));
        }
    } catch (e) {
        if (e instanceof Response) throw e;
    }
    throw redirect(href('/login'));
}

export default function IndexPage() {
    return null;
}