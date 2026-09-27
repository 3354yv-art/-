Ampere Launcher / שרת ענן חינמי ב-Oracle Cloud
===============================================

מה זה עושה:
  מנסה ליצור שרת ARM חינמי (Ampere A1) ב-Oracle Cloud כל 2 דקות,
  עד שמתפנה מקום. מחליף בין 2 ליבות/12GB לבין ליבה אחת/6GB.

הדרך הכי קלה (Cloud Shell):
  1. פתח חשבון חינמי ב-Oracle Cloud והתחבר לקונסולה.
  2. לחץ על אייקון ה-Cloud Shell (>_) למעלה.
  3. העלה את ampere.sh (תפריט > Upload) והרץ:
       bash ampere.sh
  4. השאר את החלון פתוח. כשהשרת מוכן יודפסו ה-IP ופקודת ההתחברות.
  5. הורד את המפתח: תפריט > Download > oci_ampere.key

הרצה במחשב שלך (Linux / Mac):
  pip install oci-cli
  oci setup config
  bash ampere.sh

הגדרות אופציונליות (משתני סביבה):
  COMPARTMENT_ID        אחרת מזוהה אוטומטית מהחשבון
  AVAILABILITY_DOMAIN   אחרת נבחר האזור הראשון
  SSH_PUBLIC_KEY        מפתח ציבורי משלך במקום ליצור חדש
  MAX_SECONDS           לעצור אחרי זמן מסוים (0 = בלי הגבלה)
