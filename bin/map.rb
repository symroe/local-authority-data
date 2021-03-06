##
# To install dependencies:
#     bundle
#
# To run:
#     bundle exec ruby bin/map.rb
#
require 'builder'
require 'map_by_method'
require 'morph'
require 'yaml'

def load_meta file
  dir = File.split(file).first
  meta = File.join(dir, 'meta.yml')
  YAML.load_file(meta).each_with_object({}) do |x, h|
    h[x.first.to_sym] = x.last.gsub('-','_').downcase.to_sym
  end
end

def name_from file
  extension = File.extname(file)
  name = File.split(file).first.split('/').last.gsub('-','_')
  [name, extension]
end

def load_data name, extension, file
  data = IO.read(file).encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
  Morph.send(:"from_#{extension.tr('.','')}", data, name)
end

def load file
  name, extension = name_from(file)
  list = load_data(name, extension, file)
  meta = load_meta(file)
  puts "\n#{file}\n#{name}\n#{meta.inspect}"
  klass = list.first.class
  klass.class_eval("def _name; send(:#{meta[:name]}); end")
  klass.class_eval("def _id; send(:#{meta[:id]}); end")
  type = meta[:type] ? "send(:#{meta[:type]}).strip" : 'nil'
  klass.class_eval("def _type; #{type}; end")
  dataset = klass.name.sub('Morph::','').downcase
  klass.class_eval("def _dataset; '#{dataset}'; end")
  [name, list]
end

def load_data_and_legacy
  _, data = load Dir.glob('data/*/*{tsv}').first ; nil

  legacy = Dir.glob('legacy/*/*{tsv}').each_with_object({}) do |file, hash|
    name, list = load(file)
    hash[name.to_sym] = list
  end ; nil

  [data, legacy]
end

def remove_unrelated! legacy
  legacy[:local_directgov].delete_if { |item| item.snac.blank? }; nil
  legacy[:opendatacommunities].delete_if { |item| item.ons_code.blank? }; nil
end

def log_legacy legacy
  legacy.map do |name, list|
    puts ""
    puts name
    puts [list.first._id, list.first._name].join(" | ")
    puts list.first.morph_attributes.to_yaml
    puts ""
    puts ""
  end
end

def fix_mispelling! name
  name.sub!(' coucil', ' council')
  [
    ['aberdeen c ity', 'aberdeen city'],
    ['aberdeen cuty', 'aberdeen city'],
    ['comhairle nan eilean siar (western isles)', 'comhairle nan eilean siar'],
    ['merthyr tudful', 'merthyr tydfil'],
    ['merthyr tydfil ua', 'merthyr tydfil'],
    ['rhondda cynon taff', 'rhondda cynon taf'],
  ].each do |replace, with|
    name.sub!(replace, with)
  end
end

def remove_suffix! name
  [
    'county borough council',
    'metropolitan district council',
    'metropolitan borough council',
    'borough council',
    'county council',
    'district council',
    'county borough',
    'council',
    'county of',
    'city of',
  ].each do |suffix|
    name.sub!(/\s#{suffix}$/, '')
  end
end

def normalize_name item
  name = item._name.dup
  name.strip!
  name.tr!(',', ' ')
  name.tr!('.', ' ')
  name.tr!('-', ' ')
  name.gsub!(/\s+/, ' ')
  name.downcase!
  name.sub!(' & ', ' and ')

  fix_mispelling! name
  remove_suffix! name

  name.sub!(/\sand$/, '')
  name.strip!
  name
end

def group_by_normalize_name authorities, legacy
  legacy_values = legacy.except(:os_open_names).except(:map).values
  by_name = [authorities, legacy_values].flatten.
    select{|item| !normalize_name(item)[/\s(fire|police)\s/] }.
    sort_by{|item| normalize_name(item) }.
    group_by{|item| normalize_name(item) }
end

def class_keys authorities, legacy
  dataset_keys = legacy.keys.select{ |x| x != :os_open_names }
  [authorities.first.class] + dataset_keys.map{|k| legacy[k].first.class}
end

def css_class value
  type = value.to_s.downcase.sub(' ','-')
  type.blank? ? 'other' : type
end

def write_to_html authorities, legacy, by_name, dataset_to_type
  class_keys = class_keys authorities, legacy

  b = Builder::XmlMarkup.new(indent: 2)
  html = b.html {
    b.head {
      b.meta('http-equiv': "content-type", content: "text/html; charset=utf-8")
      b.script(src: "https://cdnjs.cloudflare.com/ajax/libs/jquery/3.0.0-beta1/jquery.min.js", type: "text/javascript")
      b.script(src: "https://cdnjs.cloudflare.com/ajax/libs/floatthead/1.4.0/jquery.floatThead.min.js", type: "text/javascript")
      b.link(href: "https://govuk-elements.herokuapp.com/public/stylesheets/elements-page.css", rel: "stylesheet", type: "text/css")
      b.style({type: "text/css"}, '
        a { color: inherit; }
        table th, table td { font-size: 17px; }
        .city-corporation      { color: #d53880; }
        .council-area          { color: #f47738; }
        .district              { color: #006435; }
        .london-borough        { color: #912b88; }
        .metropolitan-district { color: #85994b; }
        .two-tier-county       { color: #B10E1E; }
        .unitary-authority     { color: #2b8cc4; }
        .other                 { color: #6F777B; }
      ')
    }
    b.body {
      b.table {
        b.thead {
          b.tr {
            b.th style: "background: lightgrey;"
            class_keys.each do |key|
              b.th({style: "background: lightgrey;"}, key.name.downcase.sub('morph::','') )
            end
          }
        }
        b.tbody {
          b.tr {
            b.td ''
            class_keys.each do |key|
              b.td {
                dataset = key.name.downcase.sub('morph::','')
                if types = dataset_to_type[dataset]
                  b.ul {
                    types.to_a.sort_by{|x| x.first.downcase}.each do |label, value|
                      b.li({class: css_class(value)}, label)
                    end
                  }
                end
              }
            end
          }
          all = by_name.to_a
          first = all.delete_at(0)
          all.insert(-1, first)
          all.each do |n, list|
            b.tr {
              b.td { b.b(n) }
              class_keys.each do |key|
                values = list.select {|i| i.class == key}.map do |item|
                  value = item._id
                  value += ' | ' + item._name unless item._id == item._name
                  type = 'unknown'
                  if item._type
                    value += ' | ' + item._type
                    type = css_class(dataset_to_type[item._dataset][item._type])
                  end
                  url = nil
                  if item._dataset == 'legislation'
                    url = item.legislation_gov_uk_reference
                  end
                  [value, type, url]
                end.uniq
                b.td {
                  b.ul {
                    values.sort.map do |value, type, url|
                      if url
                        b.li({class: type}) {
                          b.a({href: url, rel: 'external'}, value)
                        }
                      else
                        b.li({class: type}, value)
                      end
                    end
                  }
                }
              end
            }
          end
        }
      }
      b.script({ type: "text/javascript"}, '$("table").floatThead({position: "fixed"});')
    }
  }
  html = html.to_s
  html.gsub!('type="text/javascript"/>','type="text/javascript"></script>')
  file = 'legacy/report.html'
  File.open(file, 'w') do |f|
    f.write('<!DOCTYPE html>')
    f.write("\n")
    f.write(html)
    f.write("\n")
  end
  puts "\nFile written to #{file}\n"
end

authorities, legacy = load_data_and_legacy ; nil
remove_unrelated! legacy ; nil

log_legacy legacy

by_name = group_by_normalize_name(authorities, legacy) ; nil

type_to_aliases = by_name.to_a.map {|key, list| list.each_with_object({}) {|item, hash| if type = item.try(:_type) ; hash[item._dataset] = type ; end } }.uniq.select {|x| x.size > 1}.group_by{|x| x['localauthority']}

dataset_to_type = type_to_aliases.to_a.each_with_object({}) {|to_alias, h| mapping = to_alias.last ; type = to_alias.first ; mapping.each {|submap| submap.keys.each {|dataset| h[dataset] ||= {}; h[dataset][submap[dataset]] = type} } }
dataset_to_type['localauthority']['district'] = 'district'
dataset_to_type['legislation']['Local Government District'] = 'district'

write_to_html authorities, legacy, by_name, dataset_to_type

puts 'Write file to: maps/map2.tsv'
File.open('maps/map2.tsv', 'w') do |f|
  class_keys = class_keys authorities, legacy
  class_keys.each do |key|
    f.write(key.name.sub('Morph::','').underscore.gsub('_','-'))
    f.write("\t")
    f.write(key.name.sub('Morph::','').underscore.gsub('_','-') + '-name')
    f.write("\t")
  end
  f.write("\n")
  all = by_name.to_a
  first = all.delete_at(0)
  all.each do |n, list|
    class_keys.each do |key|
      values = list.select {|i| i.class == key}.map do |item|
        value = item._id
      end.join(';')
      f.write(values)
      f.write("\t")
      names = list.select {|i| i.class == key}.map do |item|
        if item._id != item._name
          value = item._name
        else
          ''
        end
      end.join(';')
      f.write(names)
      f.write("\t")
    end
    f.write("\n")
  end
end