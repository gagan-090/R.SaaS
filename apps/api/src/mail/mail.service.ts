import { Injectable, Logger } from '@nestjs/common';
import * as nodemailer from 'nodemailer';
import { loadEnv } from '../config/env';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
}

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
    await this.transport.sendMail({ from: loadEnv().MAIL_FROM, to: msg.to, subject: msg.subject, text: msg.text });
  }
}

export const mailerProvider = {
  provide: Mailer,
  useFactory: () => (loadEnv().SMTP_HOST ? new SmtpMailer() : new ConsoleMailer()),
};
