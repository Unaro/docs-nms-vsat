import { href, redirect } from "react-router";
import { nmsApi } from "~/api";


export async function clientLoader() {
    throw redirect(href('/login'))
}

export async function clientAction() {
    nmsApi.logout()

    return redirect(href('/login'))
}