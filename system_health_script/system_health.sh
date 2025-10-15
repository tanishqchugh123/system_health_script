#!/bin/bash

echo "Calculator for kids"

read -p "enter 1st number: " num1

read -p "enter 2nd number: " num2

read -p "enter the operation you want to perform from the following: '+' , '-' , '/' , '*' " op

if [[ $op == '+' ]];
then
	echo "The sum will be: $((num1 + num2)) "
elif [[ $op == '-' ]];
then
        echo "The substraction will be: $((num1 - num2)) "
elif [[ $op == '/' ]];
then
       echo "The division will be: $((num1 / num2)) "
elif [[ $op == '*' ]];
then	
       echo "The multiplication will be: $((num1 * num2)) "
else
      echo "enter the correct operation" 
fi      
