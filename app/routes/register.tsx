import { href, Link, redirect, useNavigation } from "react-router"
import type { Route } from "./+types/register"
import { AuthForm } from "~/components/AuthForm"
import { authenticate, currentUser, safeRedirect } from "~/lib/auth.server";
import { Field, FieldContent, FieldError, FieldTitle } from "~/components/ui/field";


export async function loader({ request }: Route.LoaderArgs) {
    if (await currentUser(request)) return redirect(safeRedirect(request));
    return null;
}

export async function action({request}: Route.ActionArgs) {
    const user = await request.formData();
    try {
        const email = String(user.get("email") || "").trim();
        const password = String(user.get("password") || "");
        return await authenticate(request, { email, password }, true);
    } catch(e) {
        if (e instanceof Response) throw e;
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