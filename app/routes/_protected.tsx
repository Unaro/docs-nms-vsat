import type { User } from "~/types/user.types";
import type { Route } from "./+types/_protected";
import { href, NavLink, Outlet, redirect, useNavigation } from "react-router";
import { nmsApi } from "~/api";
import { cn } from "cn";
import { SidebarInset, SidebarProvider, SidebarTrigger } from "~/components/ui/sidebar";
import { AppSidebar } from "~/components/AppSidebar";

export interface ProtectedContext {
    user: User
}

export async function clientLoader({request}: Route.ClientLoaderArgs) {
    try {
        const user = await nmsApi.currentUser();
        
        return user;
    } catch (e) {
        if (e instanceof Response) throw e;
        const url = new URL(request.url);
        const redirectTo = encodeURIComponent(url.pathname + url.search);
        throw redirect(href('/login')+`?redirectTo=${redirectTo}`);
    }
}


export default function ProtectedLayout({loaderData}: Route.ComponentProps) {

    const TABS = [
        {path: href('/dashboard'), label: 'Дашборд'},
        {path: '', label: 'Клиенты'},
    ]


    if (loaderData.role === 'admin') {
        TABS.push(        
            {path: '', label: 'Пользователи'},
            {path: '', label: 'База данных'}
        )
    } 

    const navigation = useNavigation()
    const isLogginOut = navigation.formData?.get("intent") === 'logout'

    return (
        <div className="flex min-h-screen flex-col [--header-height:3.5rem]"> 
        <header className="sticky top-0 z-50 h-(--header-height) w-full border-b bg-white">
            <nav className="flex items-center w-full h-full gap-4 py-3 px-6">
                <div className='flex text-gray-500 ml-auto text-[12px] gap-3'>
                    <NavLink to={href('/')} className={({isActive}) => cn(isActive && 'text-primary')}>Журнал</NavLink>
                    <NavLink to={href('/profile')} className={({isActive}) => cn(isActive && 'text-primary')}>Пользователь</NavLink>
                    <span>{new Date().toLocaleString('ru', { dateStyle: 'medium' })}</span>
                </div>
            </nav>
        </header>

        <SidebarProvider className="min-h-[calc(100svh-var(--header-height))]" >
            <AppSidebar tabs={TABS} isLogginOut={isLogginOut} />
            <SidebarInset>
                <main>
                    <SidebarTrigger size={'icon-lg'} className={'fixed bottom-0 m-3 bg-white shadow'} />
                    <Outlet context={{user: loaderData}}/>
                </main>
            </SidebarInset>
        </SidebarProvider>
    </div>
    )
}


