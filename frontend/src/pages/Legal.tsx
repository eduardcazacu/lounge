import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { APP_NAME } from "../config";

// The public pages App Store Connect links to: privacy policy, terms (which
// double as the Community Guidelines the iOS app asks people to agree to), and
// support. Reachable signed out, and plain on purpose — a legal page should be
// readable by anyone, on anything, without the app around it.

export const CONTACT_EMAIL = "hello@eduardcazacu.com";
const EFFECTIVE_DATE = "14 September 2026";

function LegalPage({ title, dated = true, children }: { title: string; dated?: boolean; children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white px-4 py-10 sm:px-6">
      <div className="mx-auto w-full max-w-3xl">
        <Link to="/" className="text-sm font-semibold text-slate-500 hover:text-slate-800">
          {APP_NAME}
        </Link>
        <h1 className="mt-4 text-3xl font-extrabold text-slate-900">{title}</h1>
        {dated ? <p className="mt-2 text-sm text-slate-500">Effective {EFFECTIVE_DATE}</p> : null}
        <div className="mt-8 space-y-8 text-[15px] leading-7 text-slate-700">{children}</div>
        <nav className="mt-12 flex flex-wrap gap-x-6 gap-y-2 border-t border-slate-200 pt-6 text-sm text-slate-500">
          <Link className="hover:text-slate-800" to="/privacy">Privacy Policy</Link>
          <Link className="hover:text-slate-800" to="/terms">Terms &amp; Community Guidelines</Link>
          <Link className="hover:text-slate-800" to="/support">Support</Link>
        </nav>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="text-xl font-bold text-slate-900">{title}</h2>
      <div className="mt-3 space-y-3">{children}</div>
    </section>
  );
}

function Bullets({ items }: { items: ReactNode[] }) {
  return (
    <ul className="list-disc space-y-1.5 pl-5">
      {items.map((item, index) => (
        <li key={index}>{item}</li>
      ))}
    </ul>
  );
}

const Mail = () => (
  <a className="font-medium text-slate-900 underline" href={`mailto:${CONTACT_EMAIL}`}>
    {CONTACT_EMAIL}
  </a>
);

export const Privacy = () => (
  <LegalPage title="Privacy Policy">
    <p>
      {APP_NAME} is a small, invite-based community run by Eduard Cazacu. It includes the website at
      lounge.eduardcazacu.com and the Instant app for iPhone. This policy explains what we store, why,
      and how to get rid of it. Questions go to <Mail />.
    </p>

    <Section title="What we store">
      <Bullets
        items={[
          <><strong>Your account:</strong> email address, display name, password (stored only as a salted hash), bio, colour theme and profile picture, and when you agreed to the terms.</>,
          <><strong>What you post on the website:</strong> posts, comments, likes and chat messages. Chat messages are deleted automatically after the retention period shown in the chat.</>,
          <><strong>Instant photos:</strong> end-to-end encrypted on your device before they are sent. We store only the encrypted file, which we cannot open, and delete it as soon as it has been opened or after 24 hours.</>,
          <><strong>Instant activity:</strong> who sent an instant to whom, when, its size and its timer setting. These records hold no photo and are deleted after 30 days. We also keep who you have exchanged instants with and when you last did, which is what powers your conversation list and streaks.</>,
          <><strong>Device information:</strong> each device's public encryption key and a description of the app or browser it was registered from, plus push notification tokens if you allow notifications.</>,
          <><strong>Sign-in sessions:</strong> hashed refresh tokens and when they were issued and ended.</>,
          <><strong>Safety records:</strong> people you have blocked, and reports you make or that are made about you.</>,
        ]}
      />
    </Section>

    <Section title="Reports are the one exception to encryption">
      <p>
        If you report an instant, you can choose to attach the photo you are looking at. You already see it
        decrypted, and attaching it sends a copy to us so a moderator can see what was reported. It is stored
        privately, shown only to administrators, and deleted once the report has been dealt with. If you do
        not attach it, no photo leaves your device.
      </p>
    </Section>

    <Section title="What we use it for">
      <p>
        Running the service: signing you in, delivering what you send, showing your conversations and streaks,
        sending the notifications you asked for, keeping the community safe, and replying when you contact us.
        Nothing else. There is no advertising, no tracking across other apps or websites, no analytics SDKs,
        and we never sell or rent your data.
      </p>
    </Section>

    <Section title="Who processes it for us">
      <Bullets
        items={[
          "Cloudflare — runs the service and stores files (profile pictures, post images and encrypted instants).",
          "Prisma — hosts the database.",
          "Vercel — hosts the website.",
          "Resend — sends account emails (verification, password reset, approval).",
          "Apple Push Notification service — delivers notifications to iPhone.",
        ]}
      />
      <p>They process data only to provide their service to us. Some of them may process it outside your country.</p>
    </Section>

    <Section title="Who can see what">
      <p>
        Your name, profile picture, bio and theme are visible to other members of your community group. Posts,
        comments and chat are visible to your group. An instant can only be opened by the person you sent it
        to. Administrators can see account details and reports in order to run and moderate the service.
      </p>
    </Section>

    <Section title="Deleting your data">
      <p>
        In the Instant app, open your account and choose <strong>Delete account</strong>. Your account is
        deleted immediately, together with your profile, posts, comments, likes, chat messages, instants,
        devices, blocks and notification tokens. Reports you made are kept without your name so a moderation
        decision is not lost. You can also email <Mail /> and we will do it for you.
      </p>
      <p>
        You can ask us for a copy of your data, to correct it, or to stop processing it, by emailing <Mail />.
        If you are in the EU or UK you can also complain to your data protection authority.
      </p>
    </Section>

    <Section title="Children">
      <p>{APP_NAME} is not for anyone under 16, and we do not knowingly hold data about children.</p>
    </Section>

    <Section title="Changes">
      <p>
        If this policy changes in a way that matters, we will update the date above and tell members in the
        app or by email.
      </p>
    </Section>
  </LegalPage>
);

export const Terms = () => (
  <LegalPage title="Terms & Community Guidelines">
    <p>
      These terms cover the {APP_NAME} website and the Instant app. By creating an account or using either,
      you agree to them. If you don&apos;t agree, please don&apos;t use {APP_NAME}.
    </p>

    <Section title="Zero tolerance for objectionable content and abuse">
      <p>
        {APP_NAME} is a place for friends. <strong>There is no tolerance for objectionable content or abusive
        users.</strong> You must not send, post or share anything that:
      </p>
      <Bullets
        items={[
          "is sexually explicit, or sexualises anyone under 18 in any way;",
          "harasses, threatens, bullies, stalks or intimidates anyone;",
          "promotes violence, self-harm, terrorism or hatred against people based on who they are;",
          "shares someone else's private information or intimate images without their consent;",
          "is illegal, infringes someone else's rights, or is spam, scams or malware;",
          "impersonates another person.",
        ]}
      />
      <p>
        Instant photos are end-to-end encrypted, so we cannot look at them. That makes these rules more
        important, not less: if someone breaks them, report it.
      </p>
    </Section>

    <Section title="Reporting and blocking">
      <p>
        In the Instant app you can report a photo while viewing it, or report or block a person from your
        conversations. Blocking stops the two of you from seeing or sending to each other. Every report is
        reviewed by an administrator <strong>within 24 hours</strong>. If content breaks these guidelines we
        remove it and suspend or remove the account responsible.
      </p>
    </Section>

    <Section title="Your account">
      <Bullets
        items={[
          "You must be at least 16 years old.",
          "Accounts are approved by an administrator. Use your real name and keep your password to yourself.",
          "You are responsible for what happens under your account.",
          "We may suspend or remove an account that breaks these terms, with or without notice.",
          "You can delete your account at any time from the Instant app.",
        ]}
      />
    </Section>

    <Section title="Your content">
      <p>
        What you create stays yours. You give us permission to store, transmit and display it only as needed
        to run {APP_NAME} for you and the people you share it with. That permission ends when you delete the
        content or your account, except where we must keep something to deal with a report or comply with the
        law.
      </p>
    </Section>

    <Section title="The service">
      <p>
        {APP_NAME} is provided as is, by one person, for free. We do our best to keep it running and your data
        safe, but we cannot promise it will always be available or free of errors, and to the extent the law
        allows we are not liable for losses from using it. Instants disappear by design, and there is no way to
        recover a photo once it has been opened, has expired, or was sent to a device you no longer have.
      </p>
      <p>
        We may change these terms. If a change matters, we will update the date above and tell members before
        it takes effect.
      </p>
    </Section>

    <Section title="Contact">
      <p>
        Questions, or something to report outside the app: <Mail />.
      </p>
    </Section>
  </LegalPage>
);

export const Support = () => (
  <LegalPage title="Support" dated={false}>
    <p>
      Need help with {APP_NAME} or the Instant app? Email <Mail /> and we will get back to you, usually within a
      day.
    </p>

    <Section title="Report someone or something">
      <Bullets
        items={[
          <>While viewing an instant, tap <strong>•••</strong> and choose <strong>Report</strong>. You can attach the photo so a moderator can see it.</>,
          <>From your conversations, press and hold a person, then choose <strong>Report</strong> or <strong>Block</strong>.</>,
          <>Every report is reviewed within 24 hours. For anything urgent, also email <Mail />.</>,
        ]}
      />
    </Section>

    <Section title="Unblock someone">
      <p>Open your account in the Instant app and go to <strong>Blocked people</strong>.</p>
    </Section>

    <Section title="Delete your account">
      <p>
        Open your account in the Instant app and choose <strong>Delete account</strong>. You will be asked for your
        password. Everything is deleted straight away and cannot be undone.
      </p>
    </Section>

    <Section title="Can't sign in">
      <Bullets
        items={[
          <>Forgot your password? <Link className="font-medium text-slate-900 underline" to="/forgot-password">Reset it here</Link>.</>,
          "New accounts need a verified email and an administrator's approval before they can sign in.",
        ]}
      />
    </Section>

    <Section title="An instant won't open">
      <p>
        Instant keys never leave the device that made them. Anything sent to you before you reinstalled the app
        or switched phones was locked to your old device and can&apos;t be opened on the new one. That is what keeps
        your photos private.
      </p>
    </Section>

    <Section title="Privacy">
      <p>
        See the <Link className="font-medium text-slate-900 underline" to="/privacy">Privacy Policy</Link> and the{" "}
        <Link className="font-medium text-slate-900 underline" to="/terms">Terms &amp; Community Guidelines</Link>.
      </p>
    </Section>
  </LegalPage>
);
