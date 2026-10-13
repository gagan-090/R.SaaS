import { Injectable, Logger } from '@nestjs/common';
import * as nodemailer from 'nodemailer';
import { Resend } from 'resend';
import { loadEnv } from '../config/env';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
  /** Optional rich version; the plain text is always sent too. */
  html?: string;
}

/** Raised when the provider refuses or cannot be reached, so callers can tell the user instead of failing silently. */
export class MailError extends Error {}

/** Outbound email behind an interface. Dev (no SMTP_HOST): the message — including any link — is logged instead of sent. */
export abstract class Mailer {
  abstract send(msg: MailMessage): Promise<void>;
}

@Injectable()
export class ConsoleMailer extends Mailer {
  private log = new Logger('Mail(dev)');
  async send(msg: MailMessage) {
    this.log.log(`to=${msg.to} subject="${msg.subject}"\n${msg.text}`);
  }
}

@Injectable()
export class SmtpMailer extends Mailer {
  private transport = (() => {
    const env = loadEnv();
    return nodemailer.createTransport({
      host: env.SMTP_HOST,
      port: env.SMTP_PORT ?? 587,
      auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined,
    });
  })();
  async send(msg: MailMessage) {
    await this.transport.sendMail({ from: loadEnv().MAIL_FROM, to: msg.to, subject: msg.subject, text: msg.text, html: msg.html });
  }
}

/** Resend (HTTPS API). The sandbox sender onboarding@resend.dev only delivers to the Resend account's own address
 *  until a domain is verified at resend.com/domains — then set MAIL_FROM to an address on that domain. */
@Injectable()
export class ResendMailer extends Mailer {
  private log = new Logger('Mail(resend)');
  private client = new Resend(loadEnv().RESEND_API_KEY);
  async send(msg: MailMessage) {
    const from = loadEnv().MAIL_FROM || 'House Plating <onboarding@resend.dev>';
    const { data, error } = await this.client.emails.send({ from, to: msg.to, subject: msg.subject, text: msg.text, html: msg.html });
    if (error) {
      // never log the key or the message body (it can carry a one-time link)
      this.log.warn(`not sent to ${msg.to}: ${error.name} ${error.message}`);
      throw new MailError(error.message);
    }
    this.log.log(`sent to ${msg.to} (id ${data?.id})`);
  }
}

export const mailerProvider = {
  provide: Mailer,
  useFactory: () => {
    const env = loadEnv();
    if (env.RESEND_API_KEY) return new ResendMailer();
    return env.SMTP_HOST ? new SmtpMailer() : new ConsoleMailer();
  },
};
