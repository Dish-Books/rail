import Ecto.Query

org_id = "org_01kt20xzedtqf5z2v0fd23mqj1" # Bori
{:ok, user} = Dishbooks.Users.get_user_by_email("michael@dishbooks.com")
user = Dishbooks.Repo.preload(user, [organization_users: [:organization, :role]])
scope = Dishbooks.Scope.for_user(user, org_id)

# Clean up any created vendor from previous takes
from(v in Dishbooks.Expenses.Schemas.Vendor, where: v.organization_id == ^org_id and v.name == "Hudson Greens")
|> Dishbooks.Repo.delete_all()

# Clean up past imports and attachments for ap_bills_import.csv
past_atts = Dishbooks.Repo.all(from a in Dishbooks.Documents.Schemas.Attachment, where: a.organization_id == ^org_id and a.filename == "ap_bills_import.csv")
for a <- past_atts do
  from(i in Dishbooks.Transactions.Schemas.GlReportImport, where: i.attachment_id == ^a.id) |> Dishbooks.Repo.delete_all()
  try do
    Dishbooks.Clients.Cloudflare.delete_attachment(a)
  rescue
    _ -> :ok
  end
  Dishbooks.Repo.delete(a)
end

# Also delete any dangling GlReportImport for Bori with type ap_csv
from(i in Dishbooks.Transactions.Schemas.GlReportImport, where: i.organization_id == ^org_id and i.type == :ap_csv)
|> Dishbooks.Repo.delete_all()

csv_content = """
Invoice Number,Doc Type,Vendor Name,Invoice Date,Due Date,Location,Category,Amount,Line Memo
INV-9001,Bill,Sysco,2026-08-01,2026-08-31,Bori Memorial,5110,1250.00,Prime beef delivery
INV-9002,Bill,Hudson Greens,2026-08-05,2026-09-05,Bori Montrose,5125,480.00,Fresh organic greens
"""

{:ok, attachment} = Dishbooks.Documents.create_attachment(scope, %{
  filename: "ap_bills_import.csv",
  content_type: "text/csv"
})
Dishbooks.Clients.Cloudflare.upload_attachment(attachment, csv_content)
{:ok, attachment} = Dishbooks.Documents.finish_attachment_upload(scope, attachment.id, %{content_type: "text/csv"})

File.write!("/tmp/demo_attachment_id.txt", attachment.id)
IO.puts("RESET_DONE #{attachment.id}")
