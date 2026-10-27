import { useEffect, useState } from "react";
import { MoonIcon, SunIcon } from "lucide-react";
import { Button } from "~/components/ui/button";

export function ThemeToggle() {
  const [isDark, setIsDark] = useState<boolean | null>(null);

  useEffect(() => {
    setIsDark(document.documentElement.classList.contains("dark"));
  }, []);

  const toggle = () => {
    const next = !isDark;
    setIsDark(next);
    document.documentElement.classList.toggle("dark", next);
    try { localStorage.theme = next ? "dark" : "light"; } catch { /* private mode */ }
  };

  if (isDark === null) return <Button variant="ghost" size="icon" aria-label="Тема" />;
  return (
    <Button variant="ghost" size="icon" onClick={toggle} aria-label={isDark ? "Светлая тема" : "Тёмная тема"}>
      {isDark ? <SunIcon /> : <MoonIcon />}
    </Button>
  );
}
