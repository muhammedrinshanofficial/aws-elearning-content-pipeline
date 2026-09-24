import boto3
import os
import re
from fpdf import FPDF, FPDFException

s3 = boto3.client("s3")

PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]

def sanitize(text):
    # Core PDF fonts only support Windows-1252 (256 characters). Any
    # character outside that (emoji, non-Latin scripts, rare symbols)
    # gets replaced rather than crashing the whole render.
    return text.encode("cp1252", "replace").decode("cp1252")

def strip_inline_markdown(text):
    # Bedrock's Markdown formatting instruction can produce inline
    # **bold** / *italic* / `code` markers even in body text, not just
    # headers - strip the markers, keep the inner text.
    text = re.sub(r"\*\*(.*?)\*\*", r"\1", text)
    text = re.sub(r"\*(.*?)\*", r"\1", text)
    text = re.sub(r"`(.*?)`", r"\1", text)
    return text

def render_line(pdf, text, size, height, bold=False):
    # Explicitly reset the cursor to the left margin before every call,
    # rather than trusting fpdf2 to always do this automatically - this
    # is the actual root cause of the "not enough horizontal space"
    # error (cursor drift near the page edge, unrelated to the text
    # content itself).
    pdf.set_x(pdf.l_margin)
    pdf.set_font("Helvetica", "B" if bold else "", size)
    try:
        pdf.multi_cell(0, height, text)
    except FPDFException:
        # Defensive fallback: never let one problematic line take down
        # the entire PDF (and therefore the whole pipeline execution).
        # Skip it and keep going rather than failing the whole render.
        print(f"Skipped one unrenderable line: {text!r}")

def handler(event, context):
    notes_text = event["studyNotesResult"]["notes"]
    job_name = event["transcribeResult"]["TranscriptionJobName"]

    pdf = FPDF()
    pdf.add_page()
    pdf.set_auto_page_break(auto=True, margin=15)

    for raw_line in notes_text.split("\n"):
        line = sanitize(raw_line.strip())

        if not line:
            pdf.ln(4)
        elif line.startswith("### "):
            render_line(pdf, strip_inline_markdown(line[4:]), 13, 8, bold=True)
        elif line.startswith("## "):
            render_line(pdf, strip_inline_markdown(line[3:]), 15, 9, bold=True)
        elif line.startswith("# "):
            render_line(pdf, strip_inline_markdown(line[2:]), 18, 10, bold=True)
        elif line.startswith("- ") or line.startswith("* "):
            render_line(pdf, f"    -  {strip_inline_markdown(line[2:])}", 11, 7)
        else:
            render_line(pdf, strip_inline_markdown(line), 11, 7)

    output_path = "/tmp/study_notes.pdf"
    pdf.output(output_path)

    pdf_key = f"study-notes/{job_name}.pdf"
    s3.upload_file(output_path, PROCESSED_BUCKET, pdf_key)

    return {"pdf_key": pdf_key}