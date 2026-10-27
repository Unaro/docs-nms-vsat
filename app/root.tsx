import {
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from "react-router";

import "./app.css";
import LoaderScreen from "./components/LoaderScreen/LoaderScreen";


export function HydrateFallback() {
  return <LoaderScreen />;
}

export function Layout({children}: React.PropsWithChildren) {
  return (
    <html lang="ru">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>Панель управления NMS</title>
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  )
}


export default function App() {

  return (
      <main>
        <Outlet />
      </main>
  )
}