import type { User } from "~/types/user.types";
import type { Route } from "./+types/_protected";
import { href, NavLink, Outlet, redirect, useNavigation } from "react-router";
import { requireUser } from "~/lib/auth.server";
import { cn } from "cn";
import { SidebarInset, SidebarProvider, SidebarTrigger } from "~/components/ui/sidebar";
import { AppSidebar } from "~/components/AppSidebar";
import { ThemeToggle } from "~/components/ThemeToggle";

export interface ProtectedContext {
    user: User
}

export async function loader({ request }: Route.LoaderArgs) {
    return requireUser(request);
}


export default function ProtectedLayout({loaderData}: Route.ComponentProps) {

    const TABS = [
        {path: href('/dashboard'), label: 'Дашборд'},

    ]


 

    const navigation = useNavigation()
    const isLogginOut = navigation.formData?.get("intent") === 'logout'

    return (
        <div className="flex min-h-screen flex-col [--header-height:3.5rem]"> 
        <header className="sticky top-0 z-50 h-(--header-height) w-full border-b bg-background">
            <nav className="flex items-center w-full h-full gap-4 py-3 px-6">
                <div className='flex text-muted-foreground ml-auto text-[12px] gap-3'>
                    <ThemeToggle />
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
                    <SidebarTrigger size={'icon-lg'} className={'fixed bottom-0 m-3 bg-background shadow'} />
                    <Outlet context={{user: loaderData}}/>
                </main>
            </SidebarInset>
        </SidebarProvider>
    </div>
    )
}


