import React from "react";
import { Form } from "react-router";
import { Button } from "./ui/button";
import { Field, FieldLabel } from "./ui/field";
import { Input } from "./ui/input";

interface AuthFormProps {
  isSubmitting?: boolean
  isRegister?: boolean
}

export const AuthForm: React.FC<AuthFormProps> = ({ isSubmitting = false, isRegister = false}) => {
  
  const buttonText = isRegister ? 
  ["Регистрация..", "Зарегистрироваться"] : 
  ["Вход...", "Войти"]
  
  return (
    <Form method="post">
      <Field className={'flex flex-col gap-2.5 mt-3'}>
        <FieldLabel htmlFor="email">Email</FieldLabel>
        <Input
          id="email"
          name="email"
          type="email"
          placeholder="Введите ваш email"
          required
        />

        <FieldLabel htmlFor="password">Пароль</FieldLabel>
        <Input
          id="password"
          name="password"
          type="password"
          placeholder="Введите ваш пароль"
          required
          />

        <Button type="submit" disabled={isSubmitting} size={'lg'} className={'mt-4 w-full'}>
          {isSubmitting ? buttonText[0] : buttonText[1]}
        </Button>
      </Field>
    </Form>
  );
};