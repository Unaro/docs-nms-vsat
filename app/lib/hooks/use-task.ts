import { useEffect, useState } from "react";
import { href } from "react-router";
export interface TaskState { status: string; result?: any; error_message?: string | null }
const TASK_POLL_TIMEOUT_MS = 60000;

export function useTask(taskId?: string, onComplete?: () => void) {
  const [task, setTask] = useState<TaskState | null>(null);
  useEffect(() => {
    setTask(null);
    if (!taskId) return;
    const abort = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    const startedAt = Date.now();
    let failures = 0;
    const poll = async () => {
      try {
        const response = await fetch(href('/api/tasks/:id', { id: taskId }), { signal: abort.signal, headers: { Accept: 'application/json' } });
        if (!response.ok || response.redirected) throw new Error('Не удалось получить состояние задачи');
        const next: TaskState = await response.json();
        if (abort.signal.aborted) return;
        failures = 0;
        setTask(next);
        if (['completed', 'failed', 'cancelled'].includes(next.status)) { onComplete?.(); return; }
      } catch {
        if (abort.signal.aborted) return;
        if (++failures >= 5) { setTask({ status: 'failed', error_message: 'Связь с сервером потеряна. Задача может продолжать выполняться.' }); return; }
      }
      if (Date.now() - startedAt > TASK_POLL_TIMEOUT_MS) {
        setTask({ status: 'timeout', error_message: 'Демон не ответил за отведенное время. Проверьте, что демон запущен и подключен к базе.' });
        return;
      }
      timer = setTimeout(poll, 1000);
    };
    void poll();
    return () => { abort.abort(); clearTimeout(timer); };
  }, [taskId, onComplete]);
  return task;
}
