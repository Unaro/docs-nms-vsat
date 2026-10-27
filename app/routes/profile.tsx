import { useOutletContext } from "react-router";
import type { ProtectedContext } from "./_protected";
import { cn } from "cn";
import { Field } from "~/components/ui/field";


export default function ProfilePage() {
  const { user } = useOutletContext<ProtectedContext>();
  
  return (
    <section className="mx-2 my-4.5 min-h-screen sm:max-w-xl sm:my-1 sm:mx-auto">
      <div className="flex justify-between items-center">
        <div>
          <span className="text-primary font-extrabold text-[11px] uppercase tracking-tight">Профиль</span>
          <h1>Профиль пользователя</h1>
        </div>
      </div>
      <Field className="bg-white px-4 py-6 rounded-2xl shadow">
        <h2>Информация о пользователе</h2>
        <div className="mt-4 flex flex-col gap-2">
          <p><strong>Email:</strong> {user.email}</p>
          <p><strong>Роль:</strong> <span className={cn('tracking-tight text-sm px-1 rounded-xl shadow bg-blue-50 text-blue-500', user.role === 'admin' && 'text-red-500 bg-red-50')}>{user.role}</span></p>
          <p><strong>Дата регистрации:</strong> {new Date(user.created_at).toLocaleDateString("ru-RU")}</p>
        </div>
      </Field>
    </section>
  );
}
