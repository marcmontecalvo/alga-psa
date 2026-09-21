const nodemailer = require('nodemailer');

nodemailer.createTransport({
  host: process.env.EMAIL_HOST,
  port: Number(process.env.EMAIL_PORT),
  secure: false,
}).sendMail({
  from: process.env.EMAIL_FROM,
  to: 'admin@local.test',
  subject: 'Alga local SMTP smoke',
  text: 'SMTP path from the Alga app container to Mailpit works.',
}).then((result) => {
  console.log(`Sent test email: ${result.messageId}`);
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
