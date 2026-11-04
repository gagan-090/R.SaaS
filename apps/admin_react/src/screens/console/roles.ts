import { Award, Calculator, ChefHat, ClipboardCheck, ConciergeBell, Settings2, SlidersHorizontal, type LucideIcon } from 'lucide-react';
import type { Json } from '../../api/client';

/** Built-in restaurant roles: words, icon and what each does. */
export const roleInfo: Record<string, [string, LucideIcon, string]> = {
  owner: ['Owner', Award, 'Everything, including approvals and corrections'],
  it_admin: ['Restaurant admin', Settings2, 'Employees, menu, layout, inventory, devices and reports'],
  cashier: ['Cashier', Calculator, 'Orders, bills, payments, tips'],
  waiter: ['Waiter', ConciergeBell, 'Takes orders and sends them to the kitchen'],
  chef: ['Chef', ChefHat, 'Kitchen orders, stock, consumption, wastage, replenishment'],
  auditor: ['Auditor', ClipboardCheck, 'Read-only access to records, reports and logs'],
  custom: ['Custom role', SlidersHorizontal, 'Exactly the permissions you chose for it'],
};

export const roleLabel = (u: Json) => (u.role === 'custom' ? `${u.customRoleName ?? 'Custom role'}` : roleInfo[`${u.role}`]?.[0] ?? `${u.role}`);
