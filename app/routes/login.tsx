import { href, Link, redirect, useNavigation, useSubmit } from "react-router";
import type { Route } from "./+types/login";
import { AuthForm } from "~/components/AuthForm";
import { nmsApi } from "~/api";
import { Button } from "~/components/ui/button";
import {User, UserStar } from 'lucide-react'
import { Field, FieldContent, FieldError, FieldSeparator, FieldTitle } from "~/components/ui/field";

export async function clientLoader({ request }: Route.ClientLoaderArgs) {
    try {
        await nmsApi.currentUser();

        const url = new URL(request.url);
        const redirectTo = url.searchParams.get("redirectTo");
        return redirect(redirectTo || href('/profile'));
    } catch { }
}

export async function clientAction({ request }: Route.ClientActionArgs) {
    const formData = await request.formData();
    const url = new URL(request.url);
    const redirectTo = url.searchParams.get("redirectTo");

    try {
        const email = String(formData.get("email") || "").trim();
        const password = String(formData.get("password") || "").trim();

        await nmsApi.login({ email, password });
        return redirect(redirectTo || href('/profile'));
    } catch (e) {
        return {
            errors: e instanceof Error ? e.message : "Непредвиденная ошибка!",
        };
    }
}

export default function LoginPage({ actionData }: Route.ComponentProps) {
    const navigation = useNavigation();
    const submit = useSubmit();
    
    const isSubmitting = navigation.state !== 'idle';

    const quickLogin = (email: string) => {
        const fd = new FormData();
        fd.set("email", email);
        fd.set("password", "123456");
        submit(fd, { method: "post" });
    };

    return (
        <Field className="max-w-110 mx-auto my-15 shadow px-7 py-10 bg-white rounded-2xl">
            <FieldTitle>
                <h2 className="w-full text-center" >Вход в систему</h2>
            </FieldTitle>

            <FieldContent>
                <AuthForm isSubmitting={isSubmitting} />
            </FieldContent>
            
            {actionData?.errors && (
                <FieldError>
                    {actionData.errors}
                </FieldError>
            )}

            <FieldSeparator className="my-3" />

            <FieldContent className="flex gap-2">
                <span>
                    Быстрый вход (демо-аккаунты):
                </span>
                <Button
                    type="button"
                    size={'sm'}
                    variant={'outline'}
                    onClick={() => quickLogin("admin@example.com")}
                    disabled={isSubmitting}
                >
                    <UserStar /> Администратор (admin@example.com)
                </Button>
                <Button
                    type="button"
                    size={'sm'}
                    variant={'outline'}
                    onClick={() => quickLogin("operator@example.com")}
                    disabled={isSubmitting}
                >
                    <User /> Оператор (operator@example.com)
                </Button>
            </FieldContent>

            <div className="text-gray-400 text-sm pt-2">
                <span>Нет аккаунта?</span> <Link to={href('/register')} className={'text-primary'}>Зарегистрироваться</Link>
            </div>
        </Field>
    );
}