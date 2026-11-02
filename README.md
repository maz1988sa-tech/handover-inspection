# Property Handover Inspection | فحص استلام العقار

A phone-first handover inspection laid out on the house's floor plans: tap a room to open its checks, add observations with photos and markup, then follow each one up with the developer until you confirm it is fixed.

أداة على الجوال لفحص استلام البيت على مخططاته: اضغط الغرفة لتفتح بنودها، وأضف الملاحظات بالصور والتأشير، ثم تابع كل ملاحظة مع المطوّر حتى تؤكد إصلاحها.

- The page holds no inspection data. Notes and photos live in Supabase (Postgres + Storage) and open only through a link: the owner link edits; the developer link lets the developer answer each observation with photos of the fix (a photo is required); the view link only reads. The owner accepts or rejects each answer with a note.
- لا بيانات في الصفحة نفسها؛ الملاحظات والصور في قاعدة البيانات ولا تُفتح إلا برابط: رابط المالك للتعديل، ورابط المطوّر للرد على كل ملاحظة بصورة بعد الإصلاح (الصورة إلزامية)، ورابط العرض للاطلاع فقط. والمالك يؤكد كل رد أو يرفضه مع ملاحظته.
- Backend | الخادم: `supabase/schema.sql`, `supabase/reply.sql` and `supabase/functions/hi-photo`.
