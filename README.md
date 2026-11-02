# Property Handover Inspection | فحص استلام العقار

A phone-first handover inspection laid out on the house's floor plans: tap a room to open its checks, add observations with photos and markup, and share a read-only report with the developer.

أداة على الجوال لفحص استلام البيت على مخططاته: اضغط الغرفة لتفتح بنودها، وأضف الملاحظات بالصور والتأشير، وشارك المطوّر تقريراً للعرض فقط.

- The page holds no inspection data. Notes and photos live in Supabase (Postgres + Storage) and open only through a link: the owner link edits, the developer link reads.
- لا بيانات في الصفحة نفسها؛ الملاحظات والصور في قاعدة البيانات ولا تُفتح إلا برابط: رابط المالك للتعديل، ورابط المطوّر للعرض.
- Backend | الخادم: `supabase/schema.sql` and `supabase/functions/hi-photo`.
