import { Form, href, NavLink } from "react-router"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuItem,
} from "./ui/sidebar"
import { Button } from "./ui/button"
import { cn } from "cn"

export function AppSidebar({tabs, isLogginOut}: {tabs: {label: string, path: string}[],isLogginOut: boolean}) {
  return (
    <Sidebar 
    className="top-(--header-height) h-[calc(100svh-var(--header-height))]!">
      <SidebarHeader />
      
      <SidebarContent className="pl-4">
        <SidebarMenu className="items-center gap-1" >
            {tabs.map(tab => 
            <SidebarMenuItem key={tab.path} >
                <NavLink 
                to={tab.path} 
                className={({isActive}) => cn('text-gray-800', isActive && 'text-primary pointer-events-none select-none')} >
                    {({isPending}) => isPending ? 'Загрузка...' : tab.label }
                </NavLink>
            </SidebarMenuItem>)}
            
        </SidebarMenu>
      </SidebarContent>
      <SidebarFooter className="items-center">
        <Form className="w-full px-6" method="post" action={href('/logout')}>
            <input type="hidden" name="intent" value="logout" />
            <Button type="submit" className='w-full' disabled={isLogginOut} variant={'submit'}>
                {isLogginOut ? "Выход..." : "Выйти"}
            </Button>
        </Form>
      </SidebarFooter>
    </Sidebar>
  )
}