import { href, Link, redirect, useNavigation } from "react-router"
import type { Route } from "./+types/login"
import { AuthForm } from "~/components/AuthForm"
import { nmsApi } from "~/api";
import { Field, FieldContent, FieldError, FieldTitle } from "~/components/ui/field";


export async function clientLoader({request
}: Route.ClientLoaderArgs) {
    try {
        await nmsApi.currentUser();
        
        const url = new URL(request.url);
        const redirectTo = url.searchParams.get("redirectTo");
        return redirect(redirectTo || href('/profile'));
    } catch { }
}

export async function clientAction({request}: Route.ClientActionArgs) {
    const user = await request.formData();
    try {
        const email = String(user.get("email") || "").trim();
        const password = String(user.get("password") || "").trim();
        await nmsApi.register({ email, password });
    } catch(e) {
        return {
            errors: e instanceof Error ? e.message : 'Непредвиденная ошибка!'
        };
    }

    throw redirect(href('/profile'));
}

export default function RegisterPage({actionData}: Route.ComponentProps) {
    const navigation = useNavigation()
    const isSubmitting = navigation.state === 'submitting'

    return (
        <Field className="max-w-110 mx-auto my-15 shadow px-7 py-10 bg-white rounded-2xl">
            <FieldTitle>    
                <h2 className="w-full text-center">Регистрация в систему</h2>
            </FieldTitle>
            
            <FieldContent>
                <AuthForm isSubmitting={isSubmitting} isRegister />
            </FieldContent>

            {actionData?.errors && (
                <FieldError>
                    {actionData.errors}
                </FieldError>
            )}
            <div className="text-gray-400 text-sm pt-2">
                <span>Есть аккаунт?</span> <Link to={href('/login')} className={'text-primary'}>Войти</Link>
            </div>
                
        </Field>
    )
}